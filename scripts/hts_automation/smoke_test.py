#!/usr/bin/env python3
"""
smoke_test.py — post-deploy verification for the SAIL GTX server.

Three checks, all must pass for the workflow to consider the deploy good:
  1. /health returns 200 within --timeout seconds (default 300)
  2. POST /api/classify with a tiny canary description returns 2xx
     (we don't care about correctness, only that the boot-time HTS assertion
      passed and the route is alive)
  3. Supabase hts_revisions has a row matching the expected year + rev_num

Environment:
  SAIL_GTX_HEALTHCHECK_URL    full URL to the Railway /health endpoint
  SAIL_GTX_API_BASE           base URL for /api/classify (often the same host)
  SAIL_GTX_API_AUTH_TOKEN     optional bearer token if /api/classify requires it
  SUPABASE_URL                https://<project>.supabase.co
  SUPABASE_SERVICE_ROLE_KEY   service role key (only used to read hts_revisions)
"""

from __future__ import annotations

import argparse
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


def assert_supabase_row(year: int, rev_num: int, country: str) -> None:
    base = _env("SUPABASE_URL").rstrip("/")
    key = _env("SUPABASE_SERVICE_ROLE_KEY")
    r = requests.get(
        f"{base}/rest/v1/hts_revisions",
        headers={"apikey": key, "authorization": f"Bearer {key}"},
        params={
            "select": "country_code,revision_year,revision_number,effective_date",
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


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--year", type=int, required=True)
    p.add_argument("--rev-num", type=int, required=True)
    p.add_argument("--country", default="US")
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

    assert_supabase_row(args.year, args.rev_num, args.country)
    print("smoke test passed", flush=True)


if __name__ == "__main__":
    main()
