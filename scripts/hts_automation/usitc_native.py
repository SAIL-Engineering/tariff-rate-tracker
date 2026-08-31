#!/usr/bin/env python3
"""usitc_native.py — Python port of the three R scripts the US classification
automation used to shell out to, byte-compatible where it writes files:

  scrape    ← src/01_scrape_revision_dates.R   (releaseList merge + --auto-clear-review)
  latest    ← scripts/hts_automation/latest_revision.R
  download  ← src/02_download_hts.R            (JSON + CSV archives)

Ported so the nightly needs no R toolchain. Deliberately NOT ported (they are
tariff-pipeline concerns and the R scripts remain for local use): the
Chapter 99 PDF hash probe and the archive/CSV cross-reference report in 01,
and 01's pre-2025 backfill notes.

CSV fidelity: config/revision_dates.csv is written the way readr wrote it —
LF line endings, minimal quoting, missing values as the literal string NA,
rows sorted by effective_date. Existing cells pass through verbatim.

Usage:
  usitc_native.py scrape   [--dry-run] [--auto-clear-review]
  usitc_native.py latest   [--revision 2026_rev_8]
  usitc_native.py download [--year 2026] [--formats json,csv] [--dry-run]
"""
from __future__ import annotations

import argparse
import csv
import datetime as _dt
import json
import re
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
CSV_PATH = REPO_ROOT / "config" / "revision_dates.csv"
API_URL = "https://hts.usitc.gov/reststop/releaseList"
BASE_URL = "https://www.usitc.gov/sites/default/files/tata/hts"
UA = {"User-Agent": "tariff-rate-tracker hts-automation (python)"}

FIELDS = ["revision", "effective_date", "policy_effective_date", "tpc_date",
          "policy_event", "tpc_policy_revision", "needs_review",
          "policy_family", "usitc_archive_page_url",
          "modification_source_titles", "modification_source_citations",
          "federal_register_or_source_links", "source_commentary"]


# ─── helpers.R equivalents ───────────────────────────────────────────

def parse_revision_id(revision: str) -> tuple[int, str]:
    """'2026_rev_3' -> (2026, 'rev_3'); 'rev_32' -> (2025, 'rev_32');
    'basic' -> (2025, 'basic') — mirrors helpers.R parse_revision_id."""
    m = re.match(r"^(\d{4})_(.+)$", revision)
    if m:
        return int(m.group(1)), m.group(2)
    return 2025, revision


def api_name_to_revision(api_name: str) -> str | None:
    """'2026HTSRev4' -> '2026_rev_4'; '2025HTSBasic' -> '2025_basic'."""
    m = re.match(r"^(\d{4})HTS(Basic|Rev(\d+))$", api_name or "")
    if not m:
        return None
    rev = "basic" if m.group(2) == "Basic" else f"rev_{m.group(3)}"
    return f"{m.group(1)}_{rev}"


def _read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _write_rows(path: Path, rows: list[dict[str, str]]) -> None:
    """Write the way readr's write_csv did: LF, minimal quoting, NA literal."""
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS, lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow({k: (r.get(k) if r.get(k) not in (None, "") else "NA")
                        for k in FIELDS})


def _parse_date(s: str | None):
    try:
        return _dt.date.fromisoformat((s or "").strip())
    except ValueError:
        return None


def _sort_by_date(rows: list[dict]) -> list[dict]:
    # arrange(effective_date): stable, unparseable dates last (R sorts NA last)
    return sorted(rows, key=lambda r: (_parse_date(r.get("effective_date"))
                                       or _dt.date.max))


# ─── scrape (01_scrape_revision_dates.R) ─────────────────────────────

def fetch_usitc_releases(min_year: int = 2025) -> list[dict] | None:
    """releaseList → [{revision, effective_date(date), name}], oldest first.
    Returns None on network failure (caller proceeds without changes)."""
    print("Fetching release list from USITC API...")
    try:
        with urllib.request.urlopen(
                urllib.request.Request(API_URL, headers=UA), timeout=60) as resp:
            raw = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:                        # noqa: BLE001
        print(f"  API fetch failed (network/HTTP): {exc}")
        return None
    if not raw:
        print("  API returned empty or null response.")
        return None
    required = {"name", "releaseStartDate", "status"}
    missing = required - set(raw[0] if isinstance(raw, list) else raw)
    if missing:
        sys.exit(f"USITC API response missing expected fields: "
                 f"{', '.join(sorted(missing))}\n"
                 f"API schema may have changed — update fetch_usitc_releases().")
    out = []
    for item in raw:
        rev = api_name_to_revision(item.get("name"))
        try:
            eff = _dt.datetime.strptime(item.get("releaseStartDate", ""),
                                        "%m/%d/%Y").date()
        except ValueError:
            eff = None
        if rev and eff and (eff.year >= min_year
                            or rev.startswith(str(min_year))):
            out.append({"revision": rev, "effective_date": eff,
                        "name": item["name"]})
    out.sort(key=lambda r: r["effective_date"])
    print(f"  Fetched {len(out)} releases ({min_year}+)")
    return out


def update_revision_dates(csv_path: Path, releases: list[dict],
                          dry_run: bool = False) -> bool:
    """Append API revisions missing from the CSV (needs_review=TRUE
    placeholders, publication date), preserving existing rows verbatim.
    Returns True when the CSV was (or would be) rewritten."""
    existing = _read_rows(csv_path)
    known = {r["revision"] for r in existing}
    new = [r for r in releases if r["revision"] not in known]
    if not new:
        print("\nNo new revisions found — CSV is up to date.")
        return False

    bar = "!" * 70
    print(f"\n{bar}\nACTION REQUIRED: {len(new)} new revision(s) detected\n{bar}\n")
    print("The USITC API returns publication dates, NOT policy effective dates.")
    print("New revisions (publication date shown):")
    for r in new:
        print(f"  + {r['revision']}  published {r['effective_date']}")

    today = _dt.date.today().isoformat()
    rows = existing + [{
        "revision": r["revision"],
        "effective_date": r["effective_date"].isoformat(),
        "policy_event": f"[REVIEW] added {today} — effective_date is "
                        f"publication date, not policy date",
        "needs_review": "TRUE",
    } for r in new]
    rows = _sort_by_date(rows)
    if dry_run:
        print(f"\n[DRY RUN] Would write {len(rows)} revisions to {csv_path}")
    else:
        _write_rows(csv_path, rows)
        print(f"\nWrote {len(rows)} revisions to {csv_path}")
    return True


def auto_clear_needs_review(csv_path: Path, dry_run: bool = False) -> int:
    """Clear needs_review=TRUE on rows that pass the sanity checks:
    parseable date, within [today-60d, today+365d], year prefix matches."""
    rows = _read_rows(csv_path)
    today = _dt.date.today()
    cleared = 0
    for r in rows:
        if (r.get("needs_review") or "").upper() != "TRUE":
            continue
        rev_id, raw = r.get("revision", ""), r.get("effective_date")
        d = _parse_date(raw)
        reasons = []
        if d is None:
            reasons.append(f'effective_date does not parse: "{raw}"')
        else:
            if d < today - _dt.timedelta(days=60):
                reasons.append(f"effective_date is more than 60 days in the past ({d})")
            if d > today + _dt.timedelta(days=365):
                reasons.append(f"effective_date is more than 365 days in the future ({d})")
            rev_year, _ = parse_revision_id(rev_id)
            if rev_year != d.year:
                reasons.append(f"revision year ({rev_year}) does not match "
                               f"effective_date year ({d.year})")
        if reasons:
            print(f"  Kept needs_review = TRUE for {rev_id}:")
            for why in reasons:
                print(f"    - {why}")
        else:
            r["needs_review"] = "FALSE"
            cleared += 1
            print(f"  Cleared needs_review for {rev_id} ({d})")
    if cleared:
        if dry_run:
            print(f"\n  [DRY RUN] Would clear {cleared} row(s); not writing.")
        else:
            _write_rows(csv_path, rows)
            print(f"\n  Wrote {cleared} row(s) with needs_review = FALSE to {csv_path}")
    else:
        print("  No rows currently flagged needs_review = TRUE."
              if not any((r.get("needs_review") or "").upper() == "TRUE"
                         for r in rows) else "")
    return cleared


# ─── latest (latest_revision.R) ──────────────────────────────────────

def latest_revision(csv_path: Path, override: str | None = None) -> dict:
    rows = [r for r in _read_rows(csv_path)
            if r.get("revision") and _parse_date(r.get("effective_date"))]
    if not rows:
        sys.exit(f"No rows with a parseable effective_date in {csv_path}")
    if override:
        picked = [r for r in rows if r["revision"] == override]
        if not picked:
            sys.exit(f"Override --revision {override} not found in revision_dates.csv")
        picked = picked[0]
    else:
        eligible = [r for r in rows
                    if (r.get("needs_review") or "FALSE").upper() != "TRUE"]
        if not eligible:
            sys.exit("No eligible revisions (all rows are needs_review = TRUE).")
        picked = max(eligible, key=lambda r: _parse_date(r["effective_date"]))
    if (picked.get("needs_review") or "FALSE").upper() == "TRUE":
        sys.exit(f"Selected revision {picked['revision']} still has "
                 f"needs_review = TRUE. Run the scrape with --auto-clear-review "
                 f"or clear manually.")
    year, rev = parse_revision_id(picked["revision"])
    if rev == "basic":
        rev_num, stem = "basic", f"hts_{year}_basic"
    elif rev.startswith("rev_"):
        rev_num = rev[4:]
        stem = f"hts_{year}_rev_{rev_num}"
    else:
        sys.exit(f"Unknown revision shape: {rev}")
    d = _parse_date(picked["effective_date"])
    return {
        "REV_ID": picked["revision"],
        "YEAR": str(year),
        "REV_NUM": rev_num,
        "EFFECTIVE_DATE": d.isoformat(),
        # "August 24, 2026" — full month name, non-padded day (R: %B %e collapsed)
        "EFFECTIVE_DATE_LABEL": f"{d.strftime('%B')} {d.day}, {d.year}",
        "JSON_PATH": f"data/hts_archives/{stem}.json",
        "CSV_PATH": f"data/hts_archives_csv/{stem}.csv",
    }


# ─── download (02_download_hts.R) ────────────────────────────────────

def build_download_url(revision: str, fmt: str = "json") -> str:
    year, rev = parse_revision_id(revision)
    suffix = "_json.json" if fmt == "json" else "_csv.csv"
    if rev == "basic":
        stem = "_basic_edition" if year >= 2023 else "_basic"
        return f"{BASE_URL}/hts_{year}{stem}{suffix}"
    if rev.startswith("rev_"):
        return f"{BASE_URL}/hts_{year}_revision_{rev[4:]}{suffix}"
    sys.exit(f"Unknown revision format: {revision}")


def build_local_path(revision: str, fmt: str = "json") -> Path:
    year, rev = parse_revision_id(revision)
    sub = "hts_archives" if fmt == "json" else "hts_archives_csv"
    ext = "json" if fmt == "json" else "csv"
    return REPO_ROOT / "data" / sub / f"hts_{year}_{rev}.{ext}"


def _validate(path: Path, fmt: str) -> bool:
    if fmt == "json":
        with path.open("rb") as fh:
            head = fh.read(1)
        return head in (b"{", b"[")
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        header = fh.readline()
    cols = [c.strip().strip('"') for c in header.split(",")]
    return all(c in cols for c in ("HTS Number", "Description", "Indent"))


def download_hts_file(url: str, dest: Path, fmt: str,
                      min_size_mb: float = 1.0) -> bool:
    print(f"  Downloading: {url}\n  Destination: {dest}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        # No custom User-Agent here: the www.usitc.gov static host's WAF
        # allows stock tool UAs (python-urllib, curl, libcurl) but 403s
        # custom and browser-like strings.
        with urllib.request.urlopen(url, timeout=300) as resp, \
                dest.open("wb") as out:
            while chunk := resp.read(1 << 20):
                out.write(chunk)
    except Exception as exc:                        # noqa: BLE001
        print(f"  Download failed: {exc}")
        dest.unlink(missing_ok=True)
        return False
    size_mb = dest.stat().st_size / (1024 * 1024)
    print(f"  File size: {size_mb:.1f} MB")
    if size_mb < min_size_mb:
        print(f"  WARNING: suspiciously small ({size_mb:.2f} MB < "
              f"{min_size_mb} MB). May be an error page.")
        return False
    if not _validate(dest, fmt):
        print(f"  WARNING: structural validation failed for {dest}")
        return False
    print("  Success!")
    return True


def download_missing(formats=("json", "csv"), year: int | None = None,
                     dry_run: bool = False) -> list[tuple[str, str, str]]:
    rows = [r for r in _read_rows(CSV_PATH)
            if r.get("revision") and _parse_date(r.get("effective_date"))]
    expected = [r["revision"] for r in rows]
    if year is not None:
        expected = [r for r in expected if parse_revision_id(r)[0] == year]
        if not expected:
            print(f"No revisions for year {year} in revision_dates.csv.")
            return []
    results = []
    for fmt in formats:
        missing = [r for r in expected if not build_local_path(r, fmt).is_file()]
        print(f"\n[{fmt.upper()}] expected: {len(expected)}  missing: {len(missing)}")
        if missing:
            print(f"   Missing: {', '.join(missing)}")
        for i, rev in enumerate(missing):
            if dry_run:
                results.append((rev, fmt, "missing"))
                continue
            print(f"\n[{fmt.upper()} {i + 1}/{len(missing)}] Downloading {rev}...")
            ok = download_hts_file(build_download_url(rev, fmt),
                                   build_local_path(rev, fmt), fmt)
            results.append((rev, fmt, "downloaded" if ok else "failed"))
            if i < len(missing) - 1:
                time.sleep(2)
    n_ok = sum(1 for r in results if r[2] == "downloaded")
    n_fail = sum(1 for r in results if r[2] == "failed")
    print(f"\n=== Download Summary ===\n"
          + (f"[DRY RUN] Would download: {len(results)} file(s)."
             if dry_run else f"Downloaded: {n_ok}  Failed: {n_fail}"))
    if n_fail:
        sys.exit(1)
    return results


# ─── CLI ─────────────────────────────────────────────────────────────

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scrape")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--auto-clear-review", action="store_true")
    l = sub.add_parser("latest")
    l.add_argument("--revision")
    d = sub.add_parser("download")
    d.add_argument("--year", type=int)
    d.add_argument("--formats", default="json,csv")
    d.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    if args.cmd == "scrape":
        releases = fetch_usitc_releases()
        if releases is not None:
            update_revision_dates(CSV_PATH, releases, dry_run=args.dry_run)
        else:
            print("API unavailable — no changes made.")
        if args.auto_clear_review:
            print("\n--- Auto-clearing needs_review on safe rows ---")
            auto_clear_needs_review(CSV_PATH, dry_run=args.dry_run)
    elif args.cmd == "latest":
        for k, v in latest_revision(CSV_PATH, args.revision).items():
            print(f"{k}={v}")
    elif args.cmd == "download":
        download_missing(tuple(f.strip() for f in args.formats.split(",")),
                         year=args.year, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
