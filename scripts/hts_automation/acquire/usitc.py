"""US acquisition — pure Python since 2026-08 (usitc_native.py).

  resolve()      -> newest eligible row of config/revision_dates.csv
  fetch()        -> scrape releaseList (unless skip_scrape), re-resolve,
                    download the JSON + CSV archives for the year
  check_latest() -> scrape + resolve, for the nightly --if-new gate

Previously these shelled out to src/01_scrape_revision_dates.R,
scripts/hts_automation/latest_revision.R and src/02_download_hts.R; the R
scripts remain for the tariff pipeline (which also owns the Chapter 99 PDF
probe that was deliberately not ported). usitc_native's file writes are
byte-compatible with the readr originals — verified against live runs.
"""
from __future__ import annotations

from pathlib import Path

from . import AcquireResult

import usitc_native as _native   # scripts/hts_automation is on sys.path


def _result(kv: dict) -> AcquireResult:
    for k, v in kv.items():
        print(f"{k}={v}")
    rev_num = kv["REV_NUM"]
    return AcquireResult(
        rev_id=kv["REV_ID"], year=int(kv["YEAR"]),
        rev_num=int(rev_num) if rev_num.isdigit() else rev_num,
        effective_date=kv["EFFECTIVE_DATE"],
        effective_date_label=kv["EFFECTIVE_DATE_LABEL"],
        source_csv=kv["CSV_PATH"], source_json=kv["JSON_PATH"],
    )


def resolve(spec: dict, args) -> AcquireResult:
    return _result(_native.latest_revision(
        _native.CSV_PATH, getattr(args, "revision", None)))


def _scrape(args) -> None:
    if not getattr(args, "skip_scrape", False):
        print("[acquire:usitc] scraping USITC release list")
        releases = _native.fetch_usitc_releases()
        if releases is not None:
            _native.update_revision_dates(_native.CSV_PATH, releases)
        else:
            print("[acquire:usitc] API unavailable — no changes made")
        print("--- Auto-clearing needs_review on safe rows ---")
        _native.auto_clear_needs_review(_native.CSV_PATH)
        args.skip_scrape = True          # never scrape twice in one process


def fetch(spec: dict, args) -> AcquireResult:
    _scrape(args)
    res = resolve(spec, args)
    print(f"[acquire:usitc] downloading archives for {res.year}")
    _native.download_missing(("json", "csv"), year=res.year)
    for path, what in ((res.source_json, "JSON"), (res.source_csv, "CSV")):
        if path and not Path(path).is_file():
            raise SystemExit(f"ERROR: missing {what} after download: {path}")
    return res


def check_latest(spec: dict, args):
    """Upstream check for the nightly gate: refresh the release list, then
    resolve the newest eligible revision from it."""
    from check_upstream import UpstreamCheck

    _scrape(args)
    res = resolve(spec, args)
    return UpstreamCheck(
        status="available",
        rev_id=res.rev_id, year=res.year, rev_num=res.rev_num,
        effective_date=res.effective_date,
        detail="latest eligible row in config/revision_dates.csv")
