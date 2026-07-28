#!/usr/bin/env python3
"""
pinecone_sync.py — atomic Pinecone namespace swap for one tariff corpus.

Replaces ragie_sync.py (step 5 of the rollout). Same CLI shape and the same
upload -> verify -> THEN delete-old ordering, which is why the Ragie script never
left a partition empty mid-swap.

Unlike Ragie, the retrieval scope is NOT mutated in place. Each revision gets its
own namespace (`us__2026_rev_13`), so the swap is: build the new namespace beside
the live one, verify it, and only then point Supabase at it. Rollback is one
UPDATE, and the old namespace is still there to fall back to.

Subcommands:
  list     Namespaces in the index with record counts.
  upsert   Load a JSONL corpus into a namespace (batches of 96).
  verify   Record-count + golden-query recall check against a namespace.
  delete   Delete a namespace.
  swap     upsert + verify, then prune namespaces older than --keep.

Environment:
  PINECONE_API_KEY      required
  PINECONE_INDEX_NAME   default "sail-tariff-dense"
  PINECONE_API_VERSION  default "2025-10"

Example:
  python3 pinecone_sync.py swap \
      --jsonl out/us_2026_rev_13.jsonl \
      --namespace us__2026_rev_13
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CONTROL_PLANE = "https://api.pinecone.io"

# Integrated-embedding text records cap at 96 per request. The 1000-record /
# 2 MB cap applies only to pre-embedded vectors, and bulk `startImport` is not
# usable here at all because it requires precomputed vectors in Parquet.
UPSERT_BATCH = 96

# Pinecone serverless is eventually consistent: the last upsert returning 200
# does not mean the records are queryable.
VERIFY_POLL_SECONDS = 5
VERIFY_TIMEOUT_SECONDS = 600

# Coarse smoke queries: everyday product language that must land in the right
# 4-digit heading. Deliberately not exhaustive — real recall measurement is
# server/scripts/evalRetrieval.ts replaying historical classifications. This
# only has to catch a corpus that loaded wrong or embedded into the wrong field.
GOLDEN_QUERIES = [
    ("stainless steel hex bolts with nuts, threaded fasteners", "7318"),
    ("men's cotton knitted t-shirt, short sleeve", "6109"),
    ("portable laptop computer, notebook", "8471"),
    ("fresh bananas", "0803"),
    ("brake pads for passenger motor vehicles", "8708"),
    ("wrist watch with mechanical display, precious metal case", "9101"),
]


def _api_key() -> str:
    key = os.environ.get("PINECONE_API_KEY", "").strip()
    if not key:
        sys.exit("ERROR: PINECONE_API_KEY env var is required")
    return key


def _headers(content_type: str = "application/json") -> dict[str, str]:
    return {
        "Api-Key": _api_key(),
        "X-Pinecone-API-Version": os.environ.get("PINECONE_API_VERSION", "2025-10"),
        "Content-Type": content_type,
    }


def _request(url: str, method: str = "GET", body: bytes | None = None,
             content_type: str = "application/json", timeout: int = 120,
             retries: int = 6) -> dict:
    """HTTP with backoff on 429/5xx.

    Pinecone meters integrated embedding per project (see EmbedRateLimiter). The
    limiter below is the primary defence; this is the safety net for when the
    estimate drifts or another process shares the project quota.
    """
    attempt = 0
    while True:
        req = urllib.request.Request(url, data=body, method=method,
                                     headers=_headers(content_type))
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:400]
            retryable = e.code == 429 or 500 <= e.code < 600
            if retryable and attempt < retries:
                wait = float(e.headers.get("Retry-After") or 0) or min(60, 2 ** attempt * 5)
                print(f"  [{e.code}] retrying in {wait:.0f}s "
                      f"(attempt {attempt + 1}/{retries})", flush=True)
                time.sleep(wait)
                attempt += 1
                continue
            sys.exit(f"ERROR: {method} {url} -> {e.code}\n{detail}")
        except urllib.error.URLError as e:
            if attempt < retries:
                wait = min(60, 2 ** attempt * 5)
                print(f"  [network] retrying in {wait:.0f}s: {e}", flush=True)
                time.sleep(wait)
                attempt += 1
                continue
            sys.exit(f"ERROR: {method} {url} -> {e}")


class EmbedRateLimiter:
    """Paces upserts against the project's embedding tokens-per-minute quota.

    Integrated-embedding upserts are metered by TOKENS EMBEDDED, not by request
    count: this project allows 250,000 tokens/min for llama-text-embed-v2 with
    input_type=passage. The full US corpus is ~1.5M tokens, so a cold load is
    inherently a ~7-minute job and WILL 429 without pacing — an unpaced run dies
    around record 3,800.

    Pacing proactively rather than relying on retry keeps the run deterministic
    and avoids burning quota on requests that were always going to be rejected.
    """

    def __init__(self, tokens_per_minute: int, headroom: float = 0.9):
        self.budget = tokens_per_minute * headroom
        self.window: list[tuple[float, int]] = []  # (timestamp, tokens)

    def take(self, tokens: int) -> None:
        while True:
            now = time.monotonic()
            self.window = [(t, n) for t, n in self.window if now - t < 60.0]
            used = sum(n for _, n in self.window)
            if used + tokens <= self.budget or not self.window:
                self.window.append((now, tokens))
                return
            # Sleep until the oldest entry ages out of the 60s window.
            sleep_for = max(0.5, 60.0 - (now - self.window[0][0]) + 0.25)
            print(f"  [pacing] {used:,.0f}/{self.budget:,.0f} tokens in window; "
                  f"sleeping {sleep_for:.1f}s", flush=True)
            time.sleep(sleep_for)


def _estimate_tokens(record: dict) -> int:
    """~4 chars/token on English tariff prose. Only chunk_text is embedded —
    every other field is metadata and costs nothing."""
    return max(1, len(str(record.get("chunk_text", ""))) // 4)


def index_host() -> str:
    name = os.environ.get("PINECONE_INDEX_NAME", "sail-tariff-dense")
    body = _request(f"{CONTROL_PLANE}/indexes/{name}")
    host = body.get("host")
    if not host:
        sys.exit(f"ERROR: index {name!r} has no host (is it still initializing?)")
    return host


def list_namespaces(host: str) -> dict[str, int]:
    body = _request(f"https://{host}/namespaces")
    return {
        n.get("name", ""): int(n.get("record_count") or 0)
        for n in body.get("namespaces", [])
    }


def upsert_jsonl(host: str, namespace: str, jsonl_path: Path) -> int:
    records = [json.loads(line) for line in jsonl_path.open(encoding="utf-8") if line.strip()]
    if not records:
        sys.exit(f"ERROR: no records in {jsonl_path}")

    missing = [r for r in records if not r.get("_id")]
    if missing:
        sys.exit(f"ERROR: {len(missing):,} records are missing an `_id` field")

    total_tokens = sum(_estimate_tokens(r) for r in records)
    tpm = int(os.environ.get("PINECONE_EMBED_TPM", "250000"))
    limiter = EmbedRateLimiter(tpm)
    eta_min = total_tokens / (tpm * 0.9) if tpm else 0
    print(f"  ~{total_tokens:,} embedding tokens at {tpm:,}/min -> ETA ~{eta_min:.1f} min",
          flush=True)

    url = f"https://{host}/records/namespaces/{namespace}/upsert"
    sent = 0
    started = time.monotonic()
    for i in range(0, len(records), UPSERT_BATCH):
        batch = records[i:i + UPSERT_BATCH]
        limiter.take(sum(_estimate_tokens(r) for r in batch))
        ndjson = "\n".join(json.dumps(r, ensure_ascii=False) for r in batch).encode("utf-8")
        _request(url, method="POST", body=ndjson, content_type="application/x-ndjson")
        sent += len(batch)
        if sent % (UPSERT_BATCH * 20) == 0 or sent == len(records):
            elapsed = time.monotonic() - started
            print(f"  upserted {sent:,}/{len(records):,} ({elapsed:.0f}s)", flush=True)
    return sent


def wait_for_count(host: str, namespace: str, expected: int) -> None:
    started = time.monotonic()
    last = -1
    while time.monotonic() - started < VERIFY_TIMEOUT_SECONDS:
        count = list_namespaces(host).get(namespace, 0)
        if count != last:
            print(f"  namespace {namespace}: {count:,}/{expected:,} records", flush=True)
            last = count
        if count >= expected:
            return
        time.sleep(VERIFY_POLL_SECONDS)
    sys.exit(
        f"ERROR: {namespace} reached only {last:,}/{expected:,} records within "
        f"{VERIFY_TIMEOUT_SECONDS}s"
    )


def golden_query_check(host: str, namespace: str, top_k: int = 30) -> int:
    """Returns the number of FAILED golden queries."""
    failures = 0
    for text, expect_heading in GOLDEN_QUERIES:
        body = _request(
            f"https://{host}/records/namespaces/{namespace}/search",
            method="POST",
            body=json.dumps({
                "query": {"inputs": {"text": text}, "top_k": top_k},
                "fields": ["code", "heading", "display_text"],
            }).encode("utf-8"),
        )
        hits = body.get("result", {}).get("hits", [])
        headings = {str(h.get("fields", {}).get("heading", "")) for h in hits}
        ok = expect_heading in headings
        top = hits[0].get("fields", {}).get("code", "?") if hits else "(none)"
        print(f"  [{'ok  ' if ok else 'FAIL'}] {text[:46]:46} expect {expect_heading} top={top}")
        if not ok:
            failures += 1
    return failures


def cmd_list(args) -> None:
    host = index_host()
    for name, count in sorted(list_namespaces(host).items()):
        print(f"{name}\t{count:,}")


def cmd_upsert(args) -> None:
    host = index_host()
    path = Path(args.jsonl)
    manifest_path = path.with_name(path.stem + ".manifest.json")

    expected = None
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        expected = manifest.get("record_count")
        print(f"[manifest] {manifest.get('jurisdiction')} {manifest.get('revision')} "
              f"expects {expected:,} records (source sha256 {str(manifest.get('source_sha256'))[:12]}...)")

    existing = list_namespaces(host).get(args.namespace, 0)
    if existing and not args.force:
        sys.exit(
            f"ERROR: namespace {args.namespace} already holds {existing:,} records. "
            f"Re-running would merge two corpora into one namespace. Pass --force to "
            f"overwrite by id, or delete the namespace first."
        )

    print(f"[upsert] {path} -> {args.namespace}")
    sent = upsert_jsonl(host, args.namespace, path)
    if expected is not None and sent != expected:
        sys.exit(f"ERROR: sent {sent:,} records but manifest declares {expected:,}")
    wait_for_count(host, args.namespace, sent)
    print(f"[upsert] done: {sent:,} records live in {args.namespace}")


def cmd_verify(args) -> None:
    host = index_host()
    count = list_namespaces(host).get(args.namespace, 0)
    if count == 0:
        sys.exit(f"ERROR: namespace {args.namespace} is empty or does not exist")
    print(f"[verify] {args.namespace}: {count:,} records")
    failures = golden_query_check(host, args.namespace)
    if failures:
        sys.exit(f"ERROR: {failures}/{len(GOLDEN_QUERIES)} golden queries failed")
    print(f"[verify] all {len(GOLDEN_QUERIES)} golden queries passed")


def cmd_delete(args) -> None:
    host = index_host()
    _request(f"https://{host}/namespaces/{args.namespace}", method="DELETE")
    print(f"deleted namespace {args.namespace}")


def _revision_sort_key(ns: str) -> tuple:
    """Sort `us__2026_rev_9` before `us__2026_rev_10` — numerically, not lexically."""
    try:
        jur, rest = ns.split("__", 1)
        year, _, num = rest.partition("_rev_")
        return (jur, int(year), int(num))
    except (ValueError, TypeError):
        return (ns, -1, -1)


def cmd_swap(args) -> None:
    host = index_host()
    prefix = args.namespace.split("__", 1)[0] + "__"
    before = {k: v for k, v in list_namespaces(host).items() if k.startswith(prefix)}
    print(f"[swap] index host {host}")
    print(f"[swap] before: {before}")

    cmd_upsert(args)
    cmd_verify(args)

    # Only prune AFTER the new namespace verifies. Keep the previous revision so
    # a rollback (NULL out hts_revisions.pinecone_namespace) still has a corpus
    # to fall back to.
    siblings = sorted(
        (n for n in list_namespaces(host) if n.startswith(prefix)),
        key=_revision_sort_key,
        reverse=True,
    )
    for stale in siblings[args.keep:]:
        print(f"[swap] pruning stale namespace {stale}")
        _request(f"https://{host}/namespaces/{stale}", method="DELETE")

    print(json.dumps({"namespace": args.namespace,
                      "record_count": list_namespaces(host).get(args.namespace, 0)}))


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Pinecone namespace sync helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("list"); sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("upsert")
    sp.add_argument("--jsonl", required=True)
    sp.add_argument("--namespace", required=True)
    sp.add_argument("--force", action="store_true")
    sp.set_defaults(func=cmd_upsert)

    sp = sub.add_parser("verify")
    sp.add_argument("--namespace", required=True)
    sp.set_defaults(func=cmd_verify)

    sp = sub.add_parser("delete")
    sp.add_argument("--namespace", required=True)
    sp.set_defaults(func=cmd_delete)

    sp = sub.add_parser("swap")
    sp.add_argument("--jsonl", required=True)
    sp.add_argument("--namespace", required=True)
    sp.add_argument("--force", action="store_true")
    sp.add_argument("--keep", type=int, default=2,
                    help="Namespaces to retain for this jurisdiction (default 2: "
                         "the new one plus the previous, so rollback has a target)")
    sp.set_defaults(func=cmd_swap)

    return p


if __name__ == "__main__":
    args = build_parser().parse_args()
    args.func(args)
