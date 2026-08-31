#!/usr/bin/env python3
"""check_upstream.py — "is there anything new to roll out?" primitives.

The nightly gate (refresh.py --if-new) asks two questions and compares:
  1. adapter.check_latest(spec, args)  -> latest UPSTREAM revision, cheaply
     (page scrape / CIRCABC folder listing — never a corpus download)
  2. supabase_latest(country)          -> latest PUBLISHED revision

Supabase is the source of truth for "published". The per-jurisdiction
registry CSVs record *acquired*, not *published* (a run can acquire and then
die before publish), so they are only used to enrich messages, never to
decide.

CLI for manual testing:
  python3 scripts/hts_automation/check_upstream.py --jurisdiction CA
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


@dataclass
class UpstreamCheck:
    """What the upstream source currently offers.

    status:
      available    a concrete newer-or-equal revision was discovered
      in_progress  a newer release exists upstream but is incomplete
                   (EU: month folder still being uploaded) — skip cleanly
      unknown      the adapter cannot check (manual sources)
    The available/up_to_date/ahead distinction is made by the CALLER after
    comparing against Supabase; the adapter only reports what it sees.
    """
    status: str                      # available | in_progress | unknown
    rev_id: str | None = None        # e.g. 2026_rev_2
    year: int | None = None
    rev_num: int | str | None = None
    effective_date: str = ""
    detail: str = ""
    extras: dict = field(default_factory=dict)


def supabase_latest(country: str) -> tuple[int, int] | None:
    """Latest (revision_year, revision_number) registered for a country, or
    None when no revision was ever registered. Raises on HTTP/network errors —
    the caller must treat that as "cannot verify", never as "nothing there"."""
    base = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not base or not key:
        raise RuntimeError("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set")
    qs = urllib.parse.urlencode({
        "select": "revision_year,revision_number",
        "country_code": f"eq.{country}",
        "order": "revision_year.desc,revision_number.desc",
        "limit": "1",
    })
    req = urllib.request.Request(
        f"{base}/rest/v1/hts_revisions?{qs}",
        headers={"apikey": key, "authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        rows = json.loads(resp.read().decode("utf-8"))
    if not rows:
        return None
    return int(rows[0]["revision_year"]), int(rows[0]["revision_number"])


def registry_has(spec: dict, rev_id: str) -> bool:
    """Message enrichment only: was this revision already ACQUIRED locally?"""
    registry = spec.get("registry")
    if not registry or not Path(registry).exists():
        return False
    with Path(registry).open(newline="", encoding="utf-8") as fh:
        return any(r.get("revision") == rev_id for r in csv.DictReader(fh))


def main() -> int:
    from acquire import get_adapter
    from spec import load_spec, spec_path_for
    import refresh as _refresh

    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--jurisdiction", "-j", required=True)
    p.add_argument("--skip-scrape", action="store_true",
                   help="usitc: reuse config/revision_dates.csv as-is")
    args = p.parse_args()
    os.chdir(HERE.parents[1])
    _refresh.load_env_file()

    spec = load_spec(spec_path_for(args.jurisdiction))
    adapter = get_adapter(spec["acquire"]["adapter"])
    check_fn = getattr(adapter, "check_latest", None)
    if check_fn is None:
        print(f"{spec['code']}: adapter {spec['acquire']['adapter']!r} cannot "
              f"check upstream (status unknown)")
        return 0
    check = check_fn(spec, args)
    print(f"{spec['code']}: upstream status={check.status} "
          f"rev={check.rev_id} effective={check.effective_date or '-'} "
          f"{('— ' + check.detail) if check.detail else ''}")
    try:
        reg = supabase_latest(spec["code"])
    except Exception as exc:                        # noqa: BLE001
        print(f"{spec['code']}: published state UNKNOWN ({exc})")
        return 1
    print(f"{spec['code']}: published latest = "
          f"{('%s_rev_%s' % reg) if reg else 'none'}")
    if check.status == "available" and reg and isinstance(check.rev_num, int):
        cmp = (check.year, check.rev_num)
        verdict = ("NEW revision available" if cmp > reg else
                   "up to date" if cmp == reg else
                   "published is AHEAD of upstream (investigate)")
        print(f"{spec['code']}: {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
