"""US acquisition: wraps the existing R scripts unchanged.

  resolve() -> Rscript scripts/hts_automation/latest_revision.R  (read-only)
  fetch()   -> Rscript src/01_scrape_revision_dates.R --auto-clear-review
               (unless skip_scrape), then re-resolve, then
               Rscript src/02_download_hts.R --year <year>

config/revision_dates.csv stays owned by the R side; this adapter only reads.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from . import AcquireResult

KEYS = ("REV_ID", "YEAR", "REV_NUM", "EFFECTIVE_DATE", "EFFECTIVE_DATE_LABEL",
        "JSON_PATH", "CSV_PATH")


def _run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"ERROR: {' '.join(cmd)} exited {proc.returncode}")
    return proc.stdout


def resolve(spec: dict, args) -> AcquireResult:
    cmd = ["Rscript", "scripts/hts_automation/latest_revision.R"]
    if getattr(args, "revision", None):
        cmd += ["--revision", args.revision]
    out = _run(cmd)
    print(out, end="")
    kv = {}
    for line in out.splitlines():
        key, _, value = line.partition("=")
        if key in KEYS:
            kv[key] = value
    missing = [k for k in KEYS if k not in kv]
    if missing:
        raise SystemExit(f"ERROR: latest_revision.R output missing {missing}")
    rev_num = kv["REV_NUM"]
    return AcquireResult(
        rev_id=kv["REV_ID"], year=int(kv["YEAR"]),
        rev_num=int(rev_num) if rev_num.isdigit() else rev_num,
        effective_date=kv["EFFECTIVE_DATE"],
        effective_date_label=kv["EFFECTIVE_DATE_LABEL"],
        source_csv=kv["CSV_PATH"], source_json=kv["JSON_PATH"],
    )


def fetch(spec: dict, args) -> AcquireResult:
    if not getattr(args, "skip_scrape", False):
        print("[acquire:usitc] scraping USITC release list")
        _run(["Rscript", "src/01_scrape_revision_dates.R", "--auto-clear-review"])
    res = resolve(spec, args)
    print(f"[acquire:usitc] downloading archives for {res.year}")
    _run(["Rscript", "src/02_download_hts.R", "--year", str(res.year)])
    for path, what in ((res.source_json, "JSON"), (res.source_csv, "CSV")):
        if path and not Path(path).is_file():
            raise SystemExit(f"ERROR: missing {what} after download: {path}")
    return res


def check_latest(spec: dict, args):
    """Upstream check for the nightly gate: refresh the USITC release list
    (the scrape updates config/revision_dates.csv), then resolve the newest
    eligible revision from it. Sets skip_scrape so a following fetch() does
    not scrape twice in the same process."""
    from check_upstream import UpstreamCheck

    if not getattr(args, "skip_scrape", False):
        print("[check:usitc] scraping USITC release list")
        _run(["Rscript", "src/01_scrape_revision_dates.R", "--auto-clear-review"])
        args.skip_scrape = True
    res = resolve(spec, args)
    return UpstreamCheck(
        status="available",
        rev_id=res.rev_id, year=res.year, rev_num=res.rev_num,
        effective_date=res.effective_date,
        detail="latest eligible row in config/revision_dates.csv")
