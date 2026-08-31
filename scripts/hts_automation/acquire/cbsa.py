"""Canada acquisition: CBSA Customs Tariff Access distribution -> TPHS CSV.

  resolve()  OFFLINE: newest data/ca_tariff_source/ca_tariff_*.csv; revision
             from the filename; effective date from the per-jurisdiction
             registry (config/jurisdictions/ca_revisions.csv) or --effective-date.
  fetch()    runs the vendored downloader (discovers T<year>[-N] on the CBSA
             menu page, EN/FR cross-checked, downloads the .accdb zip, exports
             every table via mdbtools), takes csv/TPHS.csv, asserts the
             35-column header, and copies it to the spec's dest template.

REVISION NUMBERING: CBSA labels the base edition T2026 (downloader:
revision_number 0) and updates T2026-1, T2026-2... Our registry started at
2026_rev_1 for the base edition, so the spec's acquire.options.
revision_number_offset (default 1) maps CBSA numbering onto ours. The mapping
is logged on every fetch; if CBSA's base-edition question is ever resolved
differently, change the offset in ca.json — not the code.
"""
from __future__ import annotations

import csv
import datetime as _dt
import hashlib
import json
import sys
from pathlib import Path

from . import AcquireResult
from . import manual as _manual

EXPECTED_TPHS_COLUMNS = (
    "TARIFF", "EFF_DATE", "CHANGE", "SUB_CHAP", "DESC1", "DESC2", "DESC3",
    "FOOTNOTE", "UOM", "MFN", "AUT", "NZT", "CCCT", "LDCT", "GPT", "UST",
    "MXT", "CIAT", "CT", "CRT", "IT", "NT", "SLT", "PT", "COLT", "JT", "PAT",
    "HNT", "KRT", "CEUT", "CPTPT", "UKT", "row_id", "UAT", "General Tariff",
)


def _digits(code: str) -> str:
    return "".join(ch for ch in (code or "") if ch.isdigit())


def _write_sorted(src: Path, dest: Path, header: tuple[str, ...]) -> None:
    """Canonical tariff-book sort, replicated from the legacy v4 builder's
    sort_rows_for_book(): (digits, len(digits), row_id, TARIFF). The raw
    mdb-export is in arbitrary row order; build_hts_corpus.load_rows_cbsa()
    hard-fails on anything not in document order (a child before its ancestor
    silently reparents nodes), so the sort happens HERE, once, and the
    committed file is always the sorted form — same convention as the
    committed rev_1 (which is the v4 pipeline's sorted_original output)."""
    with src.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)

    def _row_id(r):
        try:
            return int(r.get("row_id") or "")
        except ValueError:
            return 10**12

    rows.sort(key=lambda r: (_digits(r.get("TARIFF")),
                             len(_digits(r.get("TARIFF"))),
                             _row_id(r),
                             r.get("TARIFF") or ""))
    with dest.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(header), extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({c: (r.get(c) or "") for c in header})


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _effective_from_registry(spec: dict, rev_id: str) -> tuple[str, str] | None:
    registry = spec.get("registry")
    if not registry or not Path(registry).is_file():
        return None
    for r in csv.DictReader(open(registry, encoding="utf-8")):
        if r.get("revision") == rev_id:
            return r["effective_date"], r.get("effective_date_label") or r["effective_date"]
    return None


def resolve(spec: dict, args) -> AcquireResult:
    """Offline: reuse the manual adapter's glob, then fill the effective date
    from the registry so a resume needs no CLI flags."""
    opts = (spec.get("acquire") or {})
    directory = Path(opts.get("manual_dir", "data/ca_tariff_source"))
    prefix = opts.get("manual_prefix", "ca_tariff")

    class _A:  # manual.resolve reads attrs off args; give it our defaults
        source = getattr(args, "source", None)
        revision = getattr(args, "revision", None)
        effective_date = getattr(args, "effective_date", None)

    if not _A.effective_date and not _A.source:
        # peek the newest file to learn the revision, then ask the registry
        candidates = sorted(directory.glob(f"{prefix}_*_rev_*.csv"),
                            key=lambda p: p.stat().st_mtime, reverse=True)
        if candidates:
            rev_id = candidates[0].stem.replace(f"{prefix}_", "")
            found = _effective_from_registry(spec, rev_id)
            if found:
                _A.effective_date = found[0]

    spec_manual = dict(spec)
    spec_manual["acquire"] = {"options": {"dir": str(directory), "prefix": prefix}}
    return _manual.resolve(spec_manual, _A)


def fetch(spec: dict, args) -> AcquireResult:
    from .vendor import cbsa_canadian_tariff as vendor

    opts = (spec.get("acquire") or {}).get("options") or {}
    language = opts.get("language", "eng")
    table = opts.get("table", "TPHS")
    offset = int(opts.get("revision_number_offset", 1))
    dest_template = opts.get("dest", "data/ca_tariff_source/ca_tariff_{year}_rev_{number}.csv")

    out_dir = Path("data/ca_tariff_source/.cbsa_download")
    # Try the current year's tariff page first; in early January the new
    # year's page may not exist yet (T<year> unpublished) — fall back to the
    # previous year rather than hard-failing the scheduled run with an error
    # that reads like an mdbtools problem.
    rc = 1
    year = _dt.date.today().year
    for attempt_year in (year, year - 1):
        print(f"[acquire:cbsa] discovering + downloading T{attempt_year} ({language})")
        rc = vendor.main(["--year", str(attempt_year), "--language", language,
                          "--output-dir", str(out_dir)])
        if rc == 0:
            year = attempt_year
            break
        print(f"[acquire:cbsa] T{attempt_year} page not available "
              f"(downloader exited {rc})", file=sys.stderr)
    if rc != 0:
        raise SystemExit(
            f"ERROR: CBSA downloader failed for both {year} and {year - 1} — "
            f"see the messages above (network/page-structure issue, or "
            f"mdbtools missing). Fallback: export {table} elsewhere and "
            f"re-run with --acquire-adapter manual --source <csv>.")

    latest = json.loads((out_dir / str(year) / "latest.json").read_text(encoding="utf-8"))
    sel = latest["selected"]
    # The revision's own year is authoritative for naming (a January run that
    # fell back to last year's page must not stamp this year's label).
    rev_year = int(str(sel["revision"])[1:5])
    if rev_year != year:
        print(f"[acquire:cbsa] note: revision {sel['revision']} year {rev_year} "
              f"differs from page year {year}; using {rev_year}")
        year = rev_year
    cbsa_rev = sel["revision"]                      # e.g. T2026 or T2026-1
    cbsa_num = int(sel["revision_number"])          # 0 for the base edition
    effective = sel["effective_date"]
    our_num = cbsa_num + offset
    print(f"[acquire:cbsa] CBSA {cbsa_rev} (effective {effective}) -> "
          f"our revision {year}_rev_{our_num} (offset {offset:+d})")

    tables = (latest.get("csv_export") or {}).get("tables") or []
    tphs = next((t for t in tables if t["table_name"] == table), None)
    if not tphs:
        raise SystemExit(f"ERROR: table {table!r} not found in the CBSA export "
                         f"(got: {[t['table_name'] for t in tables][:10]}...)")
    src = Path(tphs["csv_file"])

    with src.open(newline="", encoding="utf-8-sig") as fh:
        header = tuple(next(csv.reader(fh)))
    if header != EXPECTED_TPHS_COLUMNS:
        missing = set(EXPECTED_TPHS_COLUMNS) - set(header)
        extra = set(header) - set(EXPECTED_TPHS_COLUMNS)
        raise SystemExit(
            f"ERROR: {table} header changed upstream.\n"
            f"  missing: {sorted(missing)}\n  unexpected: {sorted(extra)}\n"
            f"A schema change must be reviewed, not silently ingested.")

    dest = Path(dest_template.format(year=year, number=our_num))
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".csv.new")
    _write_sorted(src, tmp, EXPECTED_TPHS_COLUMNS)
    if dest.exists() and _sha256(dest) == _sha256(tmp):
        tmp.unlink()
        print(f"[acquire:cbsa] {dest} already matches the download (byte-identical)")
    else:
        if dest.exists():
            print(f"[acquire:cbsa] WARNING: {dest} exists with different content "
                  f"— overwriting (CBSA re-published, or the offset mapping is "
                  f"wrong; diff before publishing)", file=sys.stderr)
        tmp.replace(dest)
        print(f"[acquire:cbsa] wrote {dest} (canonically sorted)")

    d = _dt.date.fromisoformat(effective)
    return AcquireResult(
        rev_id=f"{year}_rev_{our_num}", year=year, rev_num=our_num,
        effective_date=effective,
        effective_date_label=f"{d.strftime('%B')} {d.day}, {d.year}",
        source_csv=str(dest),
        source_url=sel.get("access_url", ""),
        source_sha256=_sha256(dest),
        acquired_at=_dt.datetime.now(_dt.timezone.utc).isoformat(),
    )


def check_latest(spec: dict, args):
    """Cheap upstream check for the nightly gate: scrape the CBSA tariff menu
    page (one HTML GET, no .accdb download) and map the newest revision to our
    numbering. Mirrors fetch()'s year fallback for early January."""
    from check_upstream import UpstreamCheck
    from .vendor import cbsa_canadian_tariff as vendor

    opts = (spec.get("acquire") or {}).get("options") or {}
    language = opts.get("language", "eng")
    offset = int(opts.get("revision_number_offset", 1))

    session = vendor.make_session()
    year = _dt.date.today().year
    last_err: Exception | None = None
    for attempt_year in (year, year - 1):
        try:
            revs = {language: vendor.discover_language(
                session, attempt_year, language, timeout=30)}
            latest, _ = vendor.choose_latest_revision(revs, language)
            break
        except Exception as exc:                    # noqa: BLE001
            last_err = exc
            print(f"[check:cbsa] T{attempt_year} page not readable ({exc})",
                  file=sys.stderr)
    else:
        raise SystemExit(f"ERROR: CBSA check failed for {year} and {year - 1}: "
                         f"{last_err}")

    rev_year = int(str(latest.revision)[1:5])
    our_num = latest.revision_number + offset
    return UpstreamCheck(
        status="available",
        rev_id=f"{rev_year}_rev_{our_num}",
        year=rev_year, rev_num=our_num,
        effective_date=latest.effective_date,
        detail=f"CBSA {latest.revision} (offset {offset:+d})")
