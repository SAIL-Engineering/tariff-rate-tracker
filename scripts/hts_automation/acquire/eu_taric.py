"""EU acquisition: CIRCABC TARIC exports -> one canonical nomenclature CSV.

  resolve()  OFFLINE: newest data/eu_tariff_source/eu_tariff_*_rev_*.csv,
             effective date from the registry (like the CBSA adapter).
  fetch()    runs the vendored CIRCABC downloader (BFS for the release folder
             holding the required workbooks, ZIP-validated, sha256'd), then
             convert()s Nomenclature EN + Declarable codes into the canonical
             CSV committed under data/eu_tariff_source/.

REVISION MAPPING: CIRCABC releases are monthly folders (2026/08 - August).
release month N of year Y -> our revision Y_rev_N. A monthly snapshot fits
every existing constraint (int revision_number, {jur}__{year}_rev_{n}
namespaces) with no schema change. The release month is NOT a blanket legal
effective date - TARIC measures carry their own dates; we record the snapshot
month's first day and keep the nuance in the registry notes.

CANONICAL CSV (one file, one loader, like CA):
  GOODS_CODE  10 digits, zero-padded (TARIC stores codes this way)
  SUFFIX      producline: 80 = real nomenclature line; 10..70 = grouping rows
  INDENT      0 chapter / 1 heading / 1 + dash-count otherwise (verified: no
              end-dated rows, no dash-less rows below heading level in 2026-08)
  DESCRIPTION text, whitespace-collapsed
  IS_LEAF     from Declarable codes.xlsx (joined on code+suffix); the OFFICIAL
              leaf flag the builder cross-checks its own tree against
  START_DATE  as published
The builder treats SUFFIX != 80 as condition rows - the same construct as
USITC's uncoded rows - so ONE build_tree() serves the EU too.
"""
from __future__ import annotations

import csv
import datetime as _dt
import hashlib
import json
import re
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from acquire import AcquireResult
    from acquire import manual as _manual
    from acquire._xlsx_lite import first_sheet
else:
    from . import AcquireResult
    from . import manual as _manual
    from ._xlsx_lite import first_sheet

_CODE_RE = re.compile(r"^(\d{10})\s+(\d{2})$")

CANONICAL_FIELDS = ("GOODS_CODE", "SUFFIX", "INDENT", "DESCRIPTION",
                    "IS_LEAF", "START_DATE")


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _read_rows(path: Path) -> list[dict[str, str]]:
    """XLSX via the stdlib reader; CSV directly (the vendored downloader's
    csv/ output) — both yield the same column-letter dicts we need."""
    if path.suffix.lower() == ".xlsx":
        return first_sheet(str(path))
    with path.open(newline="", encoding="utf-8-sig") as fh:
        return [{chr(ord("A") + i): v for i, v in enumerate(row)}
                for row in csv.reader(fh)]


def convert(nomenclature: Path, declarable: Path, out_csv: Path,
            check_lang: Path | None = None) -> dict:
    """Join the nomenclature and the official leaf flags into the canonical CSV.

    Returns summary stats. Fails loudly on: unparseable codes, duplicate
    active suffix-80 codes, or nomenclature codes missing from the declarable
    file (the leaf flag is load-bearing — a partial join would silently
    disable the IS_LEAF completeness check downstream)."""
    nom = _read_rows(nomenclature)
    dec = _read_rows(declarable)

    # Declarable codes: A=Goods code, D=IS_LEAF, E=End date
    leaf: dict[str, str] = {}
    for r in dec[1:]:
        m = _CODE_RE.match(r.get("A", ""))
        if not m or (r.get("E") or "").strip():
            continue
        leaf[m.group(1) + m.group(2)] = (r.get("D") or "").strip()

    rows_out = []
    seen80: dict[str, int] = {}
    stats = {"rows": 0, "coded": 0, "conditions": 0, "leaves": 0,
             "end_dated_dropped": 0, "unjoined": 0}
    for r in nom[1:]:
        gc = r.get("A", "")
        m = _CODE_RE.match(gc)
        if not m:
            if gc.strip():
                raise SystemExit(f"ERROR: unparseable Goods code {gc!r} in "
                                 f"{nomenclature.name}")
            continue
        digits, suffix = m.groups()
        if (r.get("C") or "").strip():
            stats["end_dated_dropped"] += 1
            continue
        dashes = (r.get("F") or "").count("-")
        is_chapter = digits[2:] == "00000000"
        is_heading = not is_chapter and digits[4:] == "000000"
        indent = 0 if is_chapter else (1 if is_heading else 1 + dashes)
        # TARIC exports encode a non-breaking space as "|" ("80|kg"); it is
        # never meaningful text, and "|" is display_text's separator downstream.
        desc = " ".join((r.get("G") or "").replace("|", " ").split())
        if desc.isupper():
            # Chapter titles are shouted in the export; sentence-case them so
            # chunk_text reads as prose (embedding quality, prompt rendering).
            desc = desc.capitalize()
        is_leaf = ""
        if suffix == "80":
            seen80[digits] = seen80.get(digits, 0) + 1
            stats["coded"] += 1
            is_leaf = leaf.get(digits + suffix, "")
            if is_leaf == "":
                stats["unjoined"] += 1
            elif is_leaf == "1":
                stats["leaves"] += 1
        else:
            stats["conditions"] += 1
        rows_out.append({"GOODS_CODE": digits, "SUFFIX": suffix,
                         "INDENT": indent, "DESCRIPTION": desc,
                         "IS_LEAF": is_leaf,
                         "START_DATE": (r.get("B") or "").strip()})
        stats["rows"] += 1

    dupes = {d: n for d, n in seen80.items() if n > 1}
    if dupes:
        raise SystemExit(f"ERROR: {len(dupes)} duplicate active suffix-80 "
                         f"codes, first 10: {sorted(dupes)[:10]}")
    if stats["unjoined"]:
        raise SystemExit(f"ERROR: {stats['unjoined']} nomenclature lines have "
                         f"no entry in {declarable.name} — the official leaf "
                         f"flag would be incomplete")

    if check_lang and check_lang.exists():
        other = {m.group(1) for r in _read_rows(check_lang)[1:]
                 if (m := _CODE_RE.match(r.get("A", "")))
                 and m.group(2) == "80"
                 and not (r.get("C") or "").strip()}
        ours = set(seen80)
        if other and ours != other:
            print(f"WARNING: EN vs {check_lang.name} code sets differ "
                  f"(EN-only: {len(ours - other)}, other-only: {len(other - ours)}) "
                  f"— free cross-language completeness canary; investigate.",
                  file=sys.stderr)

    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with out_csv.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(CANONICAL_FIELDS))
        w.writeheader()
        w.writerows(rows_out)
    print(f"[eu_taric] {out_csv}: {stats['rows']:,} rows "
          f"({stats['coded']:,} coded, {stats['conditions']:,} grouping, "
          f"{stats['leaves']:,} official leaves)")
    return stats


def resolve(spec: dict, args) -> AcquireResult:
    opts = (spec.get("acquire") or {})
    directory = Path(opts.get("manual_dir", "data/eu_tariff_source"))
    prefix = opts.get("manual_prefix", "eu_tariff")

    class _A:
        source = getattr(args, "source", None)
        revision = getattr(args, "revision", None)
        effective_date = getattr(args, "effective_date", None)

    if not _A.effective_date and not _A.source:
        candidates = sorted(directory.glob(f"{prefix}_*_rev_*.csv"),
                            key=lambda p: p.stat().st_mtime, reverse=True)
        if candidates:
            rev_id = candidates[0].stem.replace(f"{prefix}_", "")
            registry = spec.get("registry")
            if registry and Path(registry).is_file():
                for r in csv.DictReader(open(registry, encoding="utf-8")):
                    if r.get("revision") == rev_id:
                        _A.effective_date = r["effective_date"]
                        break

    spec_manual = dict(spec)
    spec_manual["acquire"] = {"options": {"dir": str(directory), "prefix": prefix}}
    res = _manual.resolve(spec_manual, _A)
    # Best-effort: a resumed run can still build duty rates when the download
    # cache from the original acquire is on disk.
    try:
        out_dir = Path("data/eu_tariff_source/.circabc_download")
        pointer = json.loads((out_dir / "latest.json").read_text(encoding="utf-8"))
        manifest = json.loads(Path(pointer["metadata_file"]).read_text(encoding="utf-8"))
        files = {f["logical_name"]: f["local_file"] for f in manifest.get("files", [])}
        mapping = {"duties_import": "eu_duties_xlsx",
                   "geo_composition": "eu_geo_xlsx",
                   "measure_exclusions": "eu_exclusions_xlsx",
                   "measure_conditions": "eu_conditions_xlsx",
                   "addcodes_descriptions": "eu_addcodes_xlsx"}
        for logical, key in mapping.items():
            path = files.get(logical)
            if path and Path(path).is_file():
                res.extras[key] = path
    except (OSError, KeyError, ValueError):
        pass
    return res


def fetch(spec: dict, args) -> AcquireResult:
    from .vendor import eu_taric_downloader as vendor

    opts = (spec.get("acquire") or {}).get("options") or {}
    dest_template = opts.get("dest", "data/eu_tariff_source/eu_tariff_{year}_rev_{number}.csv")
    out_dir = Path("data/eu_tariff_source/.circabc_download")

    print("[acquire:eu_taric] discovering + downloading the latest CIRCABC release")
    rc = vendor.main(["--output-dir", str(out_dir), "--skip-csv"])
    if rc != 0:
        raise SystemExit(f"ERROR: CIRCABC downloader exited {rc}")

    # latest.json is a POINTER ({release_month, metadata_file, ...}); the file
    # list lives in the metadata manifest it names. (The first version of this
    # adapter read a schema that did not exist and KeyError'd on line one.)
    pointer = json.loads((out_dir / "latest.json").read_text(encoding="utf-8"))
    release = pointer["release_month"]                    # e.g. 2026-08
    manifest = json.loads(Path(pointer["metadata_file"]).read_text(encoding="utf-8"))
    year, month = (int(x) for x in release.split("-"))
    effective = f"{release}-01"

    files = {f["logical_name"]: Path(f["local_file"])
             for f in manifest.get("files", [])}
    nom = files.get("nomenclature_en")
    dec = files.get("declarable_codes")
    if not nom:
        raise SystemExit("ERROR: release metadata lacks nomenclature_en")
    if not dec:
        raise SystemExit(
            "ERROR: release metadata lacks declarable_codes — the official "
            "IS_LEAF flag is required, not optional.")
    for req, label in (("duties_import", "Duties Import 01-99.xlsx"),
                       ("geo_composition", "Geographical areas composition.xlsx"),
                       ("measure_exclusions", "Measure exclusions.xlsx")):
        if not files.get(req):
            raise SystemExit(
                f"ERROR: release lacks {label} — required for a correct "
                f"per-origin duty answer (exclusions change which origins a "
                f"measure applies to).")

    dest = Path(dest_template.format(year=year, number=month))
    convert(nom, dec, dest, check_lang=files.get("nomenclature_fr"))
    extras = {
        "eu_duties_xlsx": str(files["duties_import"]),
        "eu_geo_xlsx": str(files["geo_composition"]),
        "eu_exclusions_xlsx": str(files["measure_exclusions"]),
    }
    if files.get("measure_conditions"):
        extras["eu_conditions_xlsx"] = str(files["measure_conditions"])
    else:
        print("[acquire:eu_taric] WARNING: Measure conditions absent — "
              "conditional duties will show raw 'Cond:' strings", file=sys.stderr)
    if files.get("addcodes_descriptions"):
        extras["eu_addcodes_xlsx"] = str(files["addcodes_descriptions"])
    else:
        print("[acquire:eu_taric] WARNING: Additional codes descriptions "
              "absent — AD/CVD rows will show bare add codes", file=sys.stderr)

    d = _dt.date.fromisoformat(effective)
    return AcquireResult(
        rev_id=f"{year}_rev_{month}", year=year, rev_num=month,
        effective_date=effective,
        effective_date_label=f"{d.strftime('%B')} {d.year} TARIC snapshot",
        source_csv=str(dest),
        source_url=pointer.get("release_folder_url", ""),
        source_sha256=_sha256(dest),
        acquired_at=_dt.datetime.now(_dt.timezone.utc).isoformat(),
        extras=extras,
    )


def _cli(argv=None) -> int:
    import argparse
    p = argparse.ArgumentParser(description="EU TARIC canonical-CSV converter")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert")
    c.add_argument("--nomenclature", required=True, type=Path)
    c.add_argument("--declarable", required=True, type=Path)
    c.add_argument("--check-lang", type=Path)
    c.add_argument("--out", required=True, type=Path)
    args = p.parse_args(argv)
    convert(args.nomenclature, args.declarable, args.out, args.check_lang)
    return 0


if __name__ == "__main__":
    sys.exit(_cli())


def check_latest(spec: dict, args):
    """Cheap upstream check for the nightly gate: BFS the CIRCABC folder
    metadata (no workbook downloads) and report the newest COMPLETE release,
    or in_progress when a newer month folder exists but is still missing
    required workbooks (EU uploads a release over several days — that window
    must be a clean skip, not a red build).

    Calls the vendor's discovery functions directly: main(--check-only)
    raises TaricError on newer-but-incomplete before honoring the flag."""
    from check_upstream import UpstreamCheck
    from .vendor import eu_taric_downloader as vendor

    session = vendor.make_session()
    candidates, incomplete = vendor.discover_release_candidates(
        session, vendor.DEFAULT_ROOT_ID,
        timeout=90, max_depth=4, max_folders=1000, year=None)
    candidate = vendor.select_release(candidates, None)
    release = candidate.release_month              # e.g. "2026-08"
    if not release:
        raise SystemExit("ERROR: EU check: selected release has no "
                         "release_month — CIRCABC layout changed?")
    newer_incomplete = [(rm, miss) for rm, miss in incomplete if rm > release]
    if newer_incomplete:
        rm, miss = max(newer_incomplete)
        return UpstreamCheck(
            status="in_progress", rev_id=None,
            detail=f"release {rm} is uploading (missing: {', '.join(miss)}); "
                   f"newest complete release is {release}")
    year, month = (int(x) for x in release.split("-"))
    return UpstreamCheck(
        status="available",
        rev_id=f"{year}_rev_{month}", year=year, rev_num=month,
        effective_date=f"{release}-01",
        detail=f"CIRCABC release {release}")
