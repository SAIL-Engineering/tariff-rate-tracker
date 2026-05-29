#!/usr/bin/env python3
"""
ragie_sync.py — atomic Ragie partition swap for a single CSV.

Sequence (upload → poll-ready → delete-old). We never delete before the new
document is verified live so the partition is never empty during a swap.

Three subcommands:
  list      Print existing document IDs in the partition (one per line).
  upload    Upload a CSV, poll until status="ready", print the new doc id.
  delete    Delete a doc id from a partition.
  swap      end-to-end: upload + poll + delete every other doc in partition.

Environment:
  RAGIE_API_KEY            required
  RAGIE_BASE_URL           optional, defaults to https://api.ragie.ai

Examples:
  python ragie_sync.py swap --csv ./v5_minimal2026rev8.csv \
      --partition us_hts_2026_latest

  python ragie_sync.py list --partition us_hts_2026_latest
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Iterable

import requests


BASE_URL = os.environ.get("RAGIE_BASE_URL", "https://api.ragie.ai").rstrip("/")
READY_STATUS = "ready"
FAILED_STATUS = "failed"
DEFAULT_TIMEOUT = 600  # 10 min poll budget for status=ready
POLL_INTERVAL = 5


def _api_key() -> str:
    key = os.environ.get("RAGIE_API_KEY", "").strip()
    if not key:
        sys.exit("ERROR: RAGIE_API_KEY env var is required")
    return key


def _headers(partition: str | None = None, accept_json: bool = True) -> dict[str, str]:
    h = {"authorization": f"Bearer {_api_key()}"}
    if accept_json:
        h["accept"] = "application/json"
    if partition:
        h["partition"] = partition
    return h


def list_documents(partition: str) -> list[dict]:
    """All documents in a partition. Paginates if needed."""
    docs: list[dict] = []
    cursor: str | None = None
    while True:
        params: dict[str, str] = {}
        if cursor:
            params["cursor"] = cursor
        r = requests.get(
            f"{BASE_URL}/documents",
            headers=_headers(partition),
            params=params,
            timeout=30,
        )
        r.raise_for_status()
        body = r.json()
        docs.extend(body.get("documents", []))
        cursor = (body.get("pagination") or {}).get("next_cursor")
        if not cursor:
            break
    return docs


def upload_document(csv_path: str, partition: str) -> str:
    """Upload CSV, return the new document id."""
    if not os.path.isfile(csv_path):
        sys.exit(f"ERROR: file not found: {csv_path}")
    files = {
        "file": (
            os.path.basename(csv_path),
            open(csv_path, "rb"),
            "text/csv",
        )
    }
    data = {
        "partition": partition,
        # `mode[static]=fast` matches the prior manual script. Fast is fine
        # for plain CSV — hi_res only changes things for PDFs/images.
        "mode[static]": "fast",
    }
    r = requests.post(
        f"{BASE_URL}/documents",
        headers=_headers(accept_json=True),
        files=files,
        data=data,
        timeout=120,
    )
    r.raise_for_status()
    doc = r.json()
    doc_id = doc.get("id")
    if not doc_id:
        sys.exit(f"ERROR: Ragie did not return a document id: {doc}")
    return doc_id


def poll_until_ready(doc_id: str, partition: str, timeout: int = DEFAULT_TIMEOUT) -> str:
    """Poll a single document until status='ready'. Fail on 'failed' or timeout."""
    started = time.monotonic()
    last_status = ""
    while time.monotonic() - started < timeout:
        r = requests.get(
            f"{BASE_URL}/documents/{doc_id}",
            headers=_headers(partition),
            timeout=30,
        )
        r.raise_for_status()
        body = r.json()
        status = body.get("status", "")
        if status != last_status:
            print(f"  [{doc_id}] status={status}", flush=True)
            last_status = status
        if status == READY_STATUS:
            return status
        if status == FAILED_STATUS:
            sys.exit(f"ERROR: document {doc_id} entered status=failed: {body}")
        time.sleep(POLL_INTERVAL)
    sys.exit(
        f"ERROR: document {doc_id} did not reach status=ready within "
        f"{timeout}s (last status={last_status!r})"
    )


def delete_document(doc_id: str, partition: str) -> None:
    r = requests.delete(
        f"{BASE_URL}/documents/{doc_id}",
        headers=_headers(partition),
        timeout=30,
    )
    if r.status_code == 404:
        # already gone — idempotent delete is fine.
        print(f"  [{doc_id}] 404 (already deleted)", flush=True)
        return
    r.raise_for_status()
    print(f"  [{doc_id}] deleted", flush=True)


def cmd_list(args: argparse.Namespace) -> None:
    docs = list_documents(args.partition)
    for d in docs:
        print(f"{d['id']}\t{d.get('status', '?')}\t{d.get('name', '')}")


def cmd_upload(args: argparse.Namespace) -> None:
    new_id = upload_document(args.csv, args.partition)
    print(f"uploaded id={new_id}")
    poll_until_ready(new_id, args.partition, timeout=args.timeout)
    print(f"ready id={new_id}")


def cmd_delete(args: argparse.Namespace) -> None:
    delete_document(args.doc_id, args.partition)


def cmd_swap(args: argparse.Namespace) -> None:
    """Upload-poll-delete swap. Safe against an empty partition (no old to delete)."""
    print(f"[swap] partition={args.partition}", flush=True)

    pre = list_documents(args.partition)
    pre_ids = [d["id"] for d in pre]
    print(f"[swap] before: {len(pre_ids)} document(s): {pre_ids}", flush=True)

    print(f"[swap] uploading {args.csv}", flush=True)
    new_id = upload_document(args.csv, args.partition)
    print(f"[swap] uploaded id={new_id}; polling for ready...", flush=True)

    poll_until_ready(new_id, args.partition, timeout=args.timeout)
    print(f"[swap] new id is ready", flush=True)

    to_delete: Iterable[str] = [d for d in pre_ids if d != new_id]
    for did in to_delete:
        print(f"[swap] deleting old id={did}", flush=True)
        delete_document(did, args.partition)

    post = list_documents(args.partition)
    post_ids = [d["id"] for d in post]
    print(f"[swap] after: {len(post_ids)} document(s): {post_ids}", flush=True)
    if post_ids != [new_id]:
        sys.exit(
            f"ERROR: post-swap partition state is {post_ids}, expected [{new_id}]"
        )

    # Emit machine-readable result for the workflow to capture
    print(json.dumps({"new_document_id": new_id, "deleted_ids": list(to_delete)}))


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Ragie partition sync helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("list")
    sp.add_argument("--partition", required=True)
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("upload")
    sp.add_argument("--csv", required=True)
    sp.add_argument("--partition", required=True)
    sp.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    sp.set_defaults(func=cmd_upload)

    sp = sub.add_parser("delete")
    sp.add_argument("--doc-id", required=True)
    sp.add_argument("--partition", required=True)
    sp.set_defaults(func=cmd_delete)

    sp = sub.add_parser("swap")
    sp.add_argument("--csv", required=True)
    sp.add_argument("--partition", required=True)
    sp.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    sp.set_defaults(func=cmd_swap)

    return p


if __name__ == "__main__":
    args = build_parser().parse_args()
    args.func(args)
