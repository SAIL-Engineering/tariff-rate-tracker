#!/usr/bin/env python3
"""
supabase_insert_revision.py — upsert a row into public.hts_revisions.

Mirrors the seed shape in supabase/migrations/20260512000001_multi_country_classification.sql:
    (country_code, revision_year, revision_number, effective_date,
     effective_date_label, tariff_schedule_name, ragie_partition_id,
     jurisdiction_code, revision_label)

The unique constraint is (country_code, revision_year, revision_number), so
this script uses upsert with `on_conflict` and `ignore_duplicates=True` to
make re-runs idempotent.

Environment:
  SUPABASE_URL                  https://<project>.supabase.co
  SUPABASE_SERVICE_ROLE_KEY     service role key (bypasses RLS)

Usage:
  python supabase_insert_revision.py \
      --country US --year 2026 --rev-num 8 \
      --effective-date 2026-05-22 \
      --effective-date-label "May 22, 2026" \
      --tariff-schedule-name HTSUS \
      --ragie-partition-id us_hts_2026_latest
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import requests


def _env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        sys.exit(f"ERROR: env var {name} is required")
    return v


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--country", required=True, help="ISO-3166-1 alpha-2, e.g. US")
    p.add_argument("--year", type=int, required=True)
    p.add_argument("--rev-num", required=True, help="Numeric (8) or 'basic'")
    p.add_argument("--effective-date", required=True, help="YYYY-MM-DD")
    p.add_argument("--effective-date-label", required=True, help='e.g. "May 22, 2026"')
    p.add_argument("--tariff-schedule-name", required=True, help="e.g. HTSUS")
    p.add_argument("--ragie-partition-id", required=True)
    p.add_argument("--pinecone-namespace", default=None,
                   help="Pinecone namespace built for THIS revision, e.g. us__2026_rev_13. "
                        "Written to hts_revisions.pinecone_namespace, which the server "
                        "resolves revision-first — so setting it on a FUTURE-dated row makes "
                        "the corpus swap happen automatically on the effective date, and "
                        "NULLing it is the rollback.")
    p.add_argument("--jurisdiction-code", default=None,
                   help="Defaults to --country if omitted (matches the seed data).")
    p.add_argument("--revision-label", default=None,
                   help="Free-text label; defaults to the effective_date_label.")
    p.add_argument("--promote-country-pointer", action="store_true",
                   help="After the revision row is written, also advance "
                        "supported_countries.pinecone_namespace to the same value. "
                        "That column is the LAST-KNOWN-GOOD fallback, so only pass "
                        "this once the namespace has been verified — it is what a "
                        "rollback drops back to when the revision row is NULLed.")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    base = _env("SUPABASE_URL").rstrip("/")
    key = _env("SUPABASE_SERVICE_ROLE_KEY")

    rev_num: int | str
    try:
        rev_num = int(args.rev_num)
    except ValueError:
        # 'basic' isn't supported by the integer column today — fail loudly
        # rather than silently inserting a placeholder.
        sys.exit(f"ERROR: --rev-num must be an integer; got {args.rev_num!r}")

    row = {
        "country_code": args.country.upper(),
        "revision_year": args.year,
        "revision_number": rev_num,
        "effective_date": args.effective_date,
        "effective_date_label": args.effective_date_label,
        "tariff_schedule_name": args.tariff_schedule_name,
        "ragie_partition_id": args.ragie_partition_id,
        "jurisdiction_code": (args.jurisdiction_code or args.country).upper(),
        "revision_label": args.revision_label or args.effective_date_label,
    }
    if args.pinecone_namespace:
        row["pinecone_namespace"] = args.pinecone_namespace

    if args.dry_run:
        print(json.dumps({"dry_run": True, "row": row}, indent=2))
        return

    # PostgREST upsert on the unique constraint columns.
    # merge-duplicates (not ignore-duplicates): a re-run must be able to
    # BACKFILL pinecone_namespace onto a revision row that already exists,
    # which is exactly what happens when the corpus is rebuilt for a
    # revision that was inserted before Pinecone landed.
    url = f"{base}/rest/v1/hts_revisions"
    headers = {
        "apikey": key,
        "authorization": f"Bearer {key}",
        "content-type": "application/json",
        "prefer": "resolution=merge-duplicates,return=representation",
    }
    params = {"on_conflict": "country_code,revision_year,revision_number"}

    r = requests.post(url, headers=headers, params=params,
                      data=json.dumps([row]), timeout=30)
    if r.status_code not in (200, 201):
        sys.exit(f"ERROR: Supabase upsert failed ({r.status_code}): {r.text}")
    print(r.text)

    if args.promote_country_pointer:
        if not args.pinecone_namespace:
            sys.exit("ERROR: --promote-country-pointer requires --pinecone-namespace")
        pr = requests.patch(
            f"{base}/rest/v1/supported_countries",
            headers=headers,
            params={"country_code": f"eq.{args.country.upper()}"},
            data=json.dumps({"pinecone_namespace": args.pinecone_namespace}),
            timeout=30,
        )
        if pr.status_code not in (200, 204):
            sys.exit(f"ERROR: promoting country pointer failed ({pr.status_code}): {pr.text}")
        print(f"promoted supported_countries.pinecone_namespace = "
              f"{args.pinecone_namespace} for {args.country.upper()}")


if __name__ == "__main__":
    main()
