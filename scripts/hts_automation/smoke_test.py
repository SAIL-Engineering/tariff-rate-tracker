#!/usr/bin/env python3
"""
smoke_test.py — post-deploy verification for the SAIL GTX server.

Four checks, all must pass for the workflow to consider the deploy good:
  1. /health returns 200 within --timeout seconds (default 300)
  2. POST /api/classify with a tiny canary description returns 2xx
     (we don't care about correctness, only that the boot-time HTS assertion
      passed and the route is alive)
  3. Supabase hts_revisions has a row matching the expected year + rev_num AND
     that row carries a pinecone_namespace
  4. That Pinecone namespace actually answers canary queries correctly

Environment:
  SAIL_GTX_HEALTHCHECK_URL    full URL to the Railway /health endpoint
  SAIL_GTX_API_BASE           base URL for /api/classify (often the same host)
  SAIL_GTX_API_AUTH_TOKEN     optional bearer token if /api/classify requires it
  SUPABASE_URL                https://<project>.supabase.co
  SUPABASE_SERVICE_ROLE_KEY   service role key (only used to read hts_revisions)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import requests


def _env(name: str, required: bool = True) -> str:
    v = os.environ.get(name, "").strip()
    if not v and required:
        sys.exit(f"ERROR: env var {name} is required")
    return v


def poll_health(url: str, timeout: int) -> None:
    started = time.monotonic()
    last_status = ""
    while time.monotonic() - started < timeout:
        try:
            r = requests.get(url, timeout=10)
            if r.status_code == 200:
                print(f"[health] 200 OK ({url})", flush=True)
                return
            # A 404 is a WRONG URL, not a service still warming up. Polling it
            # for the full timeout hides a config error behind what looks like a
            # slow deploy — which is exactly what happened: the configured URL
            # was /health while the route is /api/health, so this had never
            # passed. Fail immediately and say so.
            if r.status_code == 404:
                sys.exit(
                    f"ERROR: {url} returned 404 — the health route does not exist "
                    f"at that path. The server exposes /api/health and /api/ready. "
                    f"Fix SAIL_GTX_HEALTHCHECK_URL (env file locally, repo/org "
                    f"variable for GitHub Actions)."
                )
            last_status = f"{r.status_code}"
        except requests.RequestException as e:
            last_status = f"exception={e}"
        print(f"[health] waiting... last={last_status}", flush=True)
        time.sleep(5)
    sys.exit(f"ERROR: /health did not return 200 within {timeout}s (last={last_status})")


def canary_classify(api_base: str, token: str | None) -> None:
    """POST a minimal payload to /api/classify. Treat any 2xx as success."""
    url = f"{api_base.rstrip('/')}/api/classify"
    headers = {"content-type": "application/json"}
    if token:
        headers["authorization"] = f"Bearer {token}"
    payload = {
        "productDescription": "smoke test canary — generic stainless steel screw",
        "actionMode": "enhance-and-classify",
        "source": "smoke-test",
    }
    r = requests.post(url, headers=headers, json=payload, timeout=120)
    # 2xx means the route is alive and the server didn't crash on import. We
    # don't require classification correctness here — that's a separate eval.
    if not (200 <= r.status_code < 300):
        sys.exit(f"ERROR: /api/classify returned {r.status_code}: {r.text}")
    print(f"[classify] {r.status_code} OK", flush=True)


def assert_supabase_row(year: int, rev_num: int, country: str) -> str:
    """Returns the pinecone_namespace recorded for this revision."""
    base = _env("SUPABASE_URL").rstrip("/")
    key = _env("SUPABASE_SERVICE_ROLE_KEY")
    r = requests.get(
        f"{base}/rest/v1/hts_revisions",
        headers={"apikey": key, "authorization": f"Bearer {key}"},
        params={
            "select": "country_code,revision_year,revision_number,effective_date,pinecone_namespace",
            "country_code": f"eq.{country.upper()}",
            "revision_year": f"eq.{year}",
            "revision_number": f"eq.{rev_num}",
            "limit": "1",
        },
        timeout=30,
    )
    r.raise_for_status()
    rows = r.json()
    if not rows:
        sys.exit(f"ERROR: no hts_revisions row for {country} {year} rev {rev_num}")
    print(f"[supabase] row found: {rows[0]}", flush=True)

    # The pointer is what makes the corpus visible to the server. Without this
    # assertion the rollout can advance the revision LABEL while retrieval keeps
    # answering from the previous corpus — which is exactly what happened while
    # the Ragie swap sat commented out.
    ns = rows[0].get("pinecone_namespace")
    if not ns:
        sys.exit(
            f"ERROR: hts_revisions row for {country} {year} rev {rev_num} has no "
            f"pinecone_namespace. The revision would be advertised while retrieval "
            f"still served the previous corpus."
        )
    return ns


def assert_pinecone_corpus(namespace: str, golden_queries: str | None = None) -> None:
    """Query the namespace that this rollout just built.

    Three canaries spanning very different chapters. This is not a recall
    measurement (that is server/scripts/evalRetrieval.ts) — it only has to catch
    a namespace that loaded empty, embedded into the wrong field, or was pointed
    at before it finished indexing.
    """
    api_key = _env("PINECONE_API_KEY")
    version = os.environ.get("PINECONE_API_VERSION", "2025-10")
    index = os.environ.get("PINECONE_INDEX_NAME", "sail-tariff-dense")
    headers = {"Api-Key": api_key, "X-Pinecone-API-Version": version,
               "Content-Type": "application/json"}

    meta = requests.get(f"https://api.pinecone.io/indexes/{index}", headers=headers, timeout=30)
    meta.raise_for_status()
    host = meta.json().get("host")
    if not host:
        sys.exit(f"ERROR: Pinecone index {index!r} has no host")

    canaries = [
        ("men's cotton knitted t-shirt", "6109"),
        ("stainless steel hex bolts with nuts", "7318"),
        ("fresh bananas", "0803"),
    ]
    if golden_queries:
        # Per-jurisdiction canaries: same JSON shape pinecone_sync.py consumes.
        with open(golden_queries, encoding="utf-8") as fh:
            data = json.load(fh)
        canaries = [(d["query"], d["expect_heading"]) if isinstance(d, dict)
                    else (d[0], d[1]) for d in data]
    failures = []
    for text, expect_heading in canaries:
        r = requests.post(
            f"https://{host}/records/namespaces/{namespace}/search",
            headers=headers, timeout=60,
            json={"query": {"inputs": {"text": text}, "top_k": 30},
                  "fields": ["code", "heading"]},
        )
        r.raise_for_status()
        hits = r.json().get("result", {}).get("hits", [])
        headings = {str(h.get("fields", {}).get("heading", "")) for h in hits}
        ok = expect_heading in headings
        print(f"[pinecone] {'ok  ' if ok else 'FAIL'} {text!r} -> expect {expect_heading}", flush=True)
        if not ok:
            failures.append(text)
    if failures:
        sys.exit(f"ERROR: {len(failures)}/{len(canaries)} Pinecone canaries failed in {namespace}")
    print(f"[pinecone] namespace {namespace} answering correctly", flush=True)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--year", type=int, required=True)
    p.add_argument("--rev-num", type=int, required=True)
    p.add_argument("--country", default="US")
    p.add_argument("--golden-queries", default=None,
                   help="JSON file of per-jurisdiction canary queries")
    p.add_argument("--timeout", type=int, default=300,
                   help="Per-check timeout in seconds")
    p.add_argument("--skip-classify", action="store_true",
                   help="Skip POST /api/classify (auth not yet wired)")
    args = p.parse_args()

    health_url = _env("SAIL_GTX_HEALTHCHECK_URL")
    poll_health(health_url, timeout=args.timeout)

    if not args.skip_classify:
        api_base = _env("SAIL_GTX_API_BASE")
        token = _env("SAIL_GTX_API_AUTH_TOKEN", required=False) or None
        canary_classify(api_base, token)
    else:
        print("[classify] skipped (--skip-classify)", flush=True)

    namespace = assert_supabase_row(args.year, args.rev_num, args.country)
    assert_pinecone_corpus(namespace, args.golden_queries)
    print("smoke test passed", flush=True)


if __name__ == "__main__":
    main()
