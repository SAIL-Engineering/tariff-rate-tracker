"""Swiss acquisition: BAZG Passar master data -> canonical CSVs (4 languages).

  resolve()      OFFLINE: newest data/ch_tariff_source/ch_tariff_*_rev_*.csv,
                 effective date from the registry; extras from the cache.
  fetch()        ETag-gated downloads from datahub.bazg.admin.ch (the
                 filenames never change — TariffMasterData_v6.zip is
                 regenerated daily when content changes, so HTTP ETag /
                 Last-Modified IS the version signal), XSD schema tripwire,
                 XML validation, then convert() the TariffsTree into four
                 canonical CSVs (EN = the corpus source; DE/FR/IT siblings
                 feed the Tariff Schedule page's language switcher).
  check_latest() the nightly gate — three outcomes (see below).

ONE SWISS TARIFF, TWO COUNTRIES: the 1923 Customs Treaty places
Liechtenstein inside the Swiss customs territory; this single pipeline
covers CH and LI. Jurisdiction code CH.

REVISION MAPPING: rev_id = {year}_rev_{MMDD} from the TariffMasterData XML
@created date (2026-09-01 -> 2026_rev_901) — integer, monotonic within a
year, at most one per day, and the year field dominates across years.

THE DAILY-REGENERATION PROBLEM (same design as the UK): most master-data
regenerations change rates/measures, not the nomenclature (the TariffsTree
last changed 2025-10). check_latest HEADs the ZIPs and compares ETags with
data/ch_tariff_source/state.json:
  all unchanged                     -> up to date (skip)
  tree unchanged, rates changed     -> mode=rates_only (duty artifacts
                                       reshipped under the standing corpus
                                       revision; no Pinecone/Supabase churn)
  tree changed                      -> classification-hash the EN/structure
                                       fields -> full rollout or rates_only

TREE STRUCTURE (verified live 2026-09-01): 18,270 Tariff rows ordered by
`sorter`. objType tiers: TAB section (21) / TUK subchapter (33) — structure
only, dropped from the canonical but TAB drives chapters_ch.json sections;
TN2 chapter (96, indent 0) / TN4 heading (985, indent 1) / below TN4 the
indent is 1 + padNum (verified against the real nesting: VT6 pad1 -> 2,
TN6 pad2 -> 3, TN8 pad3 -> 4, ...). VT6/VT8 leading texts -> SUFFIX 10
condition rows. TN8 (7,511, all import-valid: tn8Vkr I or I+E) are the
terminal 8-digit tariff numbers -> IS_LEAF 1. STI/STE statistical keys and
VLSI/VLSE their leading texts are NOT nomenclature (declaration statistics)
-> dropped here; they surface as informational rows in the duty data.
"""
from __future__ import annotations

import csv
import datetime as _dt
import hashlib
import json
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from acquire import AcquireResult
    from acquire import manual as _manual
else:
    from . import AcquireResult
    from . import manual as _manual

HOST = "https://datahub.bazg.admin.ch/public-resources"
REQUIRED = ("TariffsTree_v1", "TariffMasterData_v6",
            "TariffBaseMasterData_v2", "CountryCodes_v3")
TREE = "TariffsTree_v1"
SOURCE_DIR = Path("data/ch_tariff_source")
CACHE_DIR = SOURCE_DIR / ".ch_download"
STATE_PATH = SOURCE_DIR / "state.json"
LANGS = ("de", "fr", "it")


def _session():
    import requests
    s = requests.Session()
    s.headers["User-Agent"] = "sail-tariff-tracker ch_tares adapter"
    return s


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def load_state() -> dict:
    if STATE_PATH.is_file():
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    return {}


def save_state(state: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n",
                          encoding="utf-8")


def head_etags(session) -> dict:
    """{stem: {etag, last_modified}} for every required ZIP."""
    out = {}
    for stem in REQUIRED:
        resp = session.head(f"{HOST}/{stem}.zip", timeout=60)
        resp.raise_for_status()
        out[stem] = {"etag": resp.headers.get("ETag", ""),
                     "last_modified": resp.headers.get("Last-Modified", "")}
        if not out[stem]["etag"]:
            raise SystemExit(f"ERROR: {stem}.zip returned no ETag — the "
                             f"update gate depends on it (BAZG filenames "
                             f"never change)")
    return out


def download_pair(session, stem: str, dest_dir: Path) -> Path:
    """ZIP + XSD; returns the extracted XML path. The XSD is the schema
    tripwire (spec §11): its content hash is recorded and compared — a
    changed schema requires review, not silent parsing."""
    dest_dir.mkdir(parents=True, exist_ok=True)
    for ext in (".zip", ".xsd"):
        dest = dest_dir / f"{stem}{ext}"
        with session.get(f"{HOST}/{stem}{ext}", timeout=600, stream=True) as r:
            r.raise_for_status()
            with dest.open("wb") as fh:
                for chunk in r.iter_content(1 << 20):
                    fh.write(chunk)
    with zipfile.ZipFile(dest_dir / f"{stem}.zip") as z:
        names = z.namelist()
        if len(names) != 1 or not names[0].endswith(".xml"):
            raise SystemExit(f"ERROR: {stem}.zip layout changed: {names}")
        z.extract(names[0], dest_dir)
    return dest_dir / names[0]


def xml_created(path: Path) -> str:
    """The master-data creation timestamp from the XML root."""
    for _, el in ET.iterparse(path, events=("start",)):
        created = el.attrib.get("created", "")
        if not created:
            raise SystemExit(f"ERROR: {path.name} root has no @created")
        return created
    raise SystemExit(f"ERROR: empty XML {path}")


def rev_from_created(created: str) -> tuple[int, int, str]:
    """(year, rev_num MMDD, effective ISO date)."""
    d = _dt.datetime.fromisoformat(created).date()
    return d.year, d.month * 100 + d.day, d.isoformat()


# ─── tree parsing / canonical conversion ─────────────────────────────

def _parse_tree(tree_xml: Path) -> list[dict]:
    r = ET.parse(tree_xml).getroot()
    rows = []
    for t in r:
        d = {c.tag.split("}")[-1]: c for c in t}
        def g(k):
            return (d[k].text or "").strip() if k in d else ""
        texts = {x.tag.split("}")[-1]: " ".join((x.text or "").split())
                 for x in d.get("text", [])} if "text" in d else {}
        units = {x.tag.split("}")[-1]: " ".join((x.text or "").split())
                 for x in d.get("gtBem", [])} if "gtBem" in d else {}
        rows.append({"sorter": int(g("sorter")), "num": g("objNumber"),
                     "type": g("objType"), "vkr": g("tn8Vkr"),
                     "pad": int(g("padNum") or 0),
                     "from": g("validFrom"), "to": g("validTo"),
                     "gt": g("gtAns"), "texts": texts, "units": units})
    rows.sort(key=lambda x: x["sorter"])
    return rows


def classification_hash(tree_xml: Path) -> str:
    """EN + structure fields only — the corpus-reindex decision key."""
    h = hashlib.sha256()
    for x in _parse_tree(tree_xml):
        h.update(("\x1f".join([str(x["sorter"]), x["num"], x["type"],
                               str(x["pad"]), x["from"], x["to"],
                               x["texts"].get("en", "")])).encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()


def convert(tree_xml: Path, out_csv: Path) -> dict:
    """TariffsTree -> canonical CSVs: out_csv (EN) plus .de/.fr/.it
    siblings from the same single parse. See the module docstring for the
    verified tier/indent mapping."""
    rows = _parse_tree(tree_xml)
    today = _dt.date.today().isoformat()
    stats = {"rows": 0, "coded": 0, "conditions": 0, "leaves": 0,
             "dropped_stat_keys": 0, "dropped_structure": 0,
             "end_dated_dropped": 0, "source_rows": len(rows)}
    out: list[dict] = []          # language-neutral; per-lang text keyed in
    seen8: set[str] = set()
    for x in rows:
        if x["to"] and x["to"] < today:
            stats["end_dated_dropped"] += 1
            continue
        typ = x["type"]
        if typ in ("STI", "STE", "VLSI", "VLSE"):
            stats["dropped_stat_keys"] += 1
            continue
        if typ in ("TAB", "TUK"):
            stats["dropped_structure"] += 1
            continue
        if typ == "TN2":
            indent, suffix = 0, "80"
        elif typ == "TN4":
            indent, suffix = 1, "80"
        elif typ in ("TN6", "TN8"):
            indent, suffix = 1 + x["pad"], "80"
        elif typ in ("VT6", "VT8"):
            indent, suffix = 1 + x["pad"], "10"
        else:
            raise SystemExit(f"ERROR: unknown objType {typ!r} at sorter "
                             f"{x['sorter']} — TariffsTree structure changed")
        digits = x["num"].replace(".", "")
        if suffix == "80":
            if not digits.isdigit() or len(digits) not in (2, 4, 6, 8):
                raise SystemExit(f"ERROR: bad objNumber {x['num']!r} "
                                 f"({typ}, sorter {x['sorter']})")
            stats["coded"] += 1
        else:
            digits = ""
            stats["conditions"] += 1
        is_leaf = ""
        if typ == "TN8":
            if x["vkr"] not in ("I", "I+E"):
                # export-only TN8 would not be classifiable on import;
                # none exist in the verified extract — fail loudly if that
                # changes rather than silently shrinking the corpus.
                raise SystemExit(f"ERROR: TN8 {x['num']} has tn8Vkr="
                                 f"{x['vkr']!r} — import universe changed")
            if digits in seen8:
                raise SystemExit(f"ERROR: duplicate TN8 {x['num']}")
            seen8.add(digits)
            is_leaf = "1"
            stats["leaves"] += 1
        elif suffix == "80":
            is_leaf = "0"
        out.append({"digits": digits, "suffix": suffix, "indent": indent,
                    "is_leaf": is_leaf, "start": x["from"], "gt": x["gt"],
                    "texts": x["texts"], "units": x["units"]})
        stats["rows"] += 1

    out_csv.parent.mkdir(parents=True, exist_ok=True)
    for lang in ("en",) + LANGS:
        dest = (out_csv if lang == "en"
                else out_csv.with_suffix(f".{lang}.csv"))
        with dest.open("w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=["GOODS_CODE", "SUFFIX",
                                               "INDENT", "DESCRIPTION",
                                               "UNIT", "IS_LEAF",
                                               "GT_RATE", "START_DATE"])
            w.writeheader()
            for o in out:
                desc = o["texts"].get(lang) or o["texts"].get("en", "")
                if desc.isupper():
                    desc = desc.capitalize()
                w.writerow({"GOODS_CODE": o["digits"], "SUFFIX": o["suffix"],
                            "INDENT": o["indent"],
                            "DESCRIPTION": desc.replace("|", " "),
                            "UNIT": o["units"].get(lang)
                                    or o["units"].get("en", ""),
                            "IS_LEAF": o["is_leaf"],
                            "GT_RATE": o["gt"],
                            "START_DATE": o["start"]})
    print(f"[ch_tares] {out_csv} (+{'/'.join(LANGS)}): {stats['rows']:,} rows "
          f"({stats['coded']:,} coded, {stats['conditions']:,} grouping, "
          f"{stats['leaves']:,} TN8 leaves; dropped: "
          f"{stats['dropped_stat_keys']:,} statistical-key rows, "
          f"{stats['dropped_structure']:,} section/subchapter rows)")
    return stats


def make_ch_chapters(tree_xml: Path, out_json: Path) -> None:
    """chapters_ch.json from the tree's OWN structure: TN2 rows are the
    chapters, the preceding TAB row (in sorter order) is the section —
    Swiss titles, not the generic HS section file."""
    ROMAN = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
             "XI", "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII",
             "XIX", "XX", "XXI"]
    rows = _parse_tree(tree_xml)
    chapters, section, section_title = [], "", ""
    for x in rows:
        en = x["texts"].get("en", "")
        if x["type"] == "TAB":
            n = int(x["num"])
            section = ROMAN[n - 1] if 1 <= n <= len(ROMAN) else x["num"]
            section_title = en.capitalize() if en.isupper() else en
        elif x["type"] == "TN2":
            chapters.append({"chapter": x["num"],
                             "description": (en.capitalize()
                                             if en.isupper() else en),
                             "section": section,
                             "sectionTitle": section_title})
    seen = set()
    for c in chapters:
        if c["chapter"] in seen:
            raise SystemExit(f"ERROR: duplicate chapter {c['chapter']}")
        seen.add(c["chapter"])
    out_json.write_text(json.dumps(chapters, indent=2, ensure_ascii=False)
                        + "\n", encoding="utf-8")
    print(f"[ch_tares] {out_json}: {len(chapters)} chapters, "
          f"Swiss sections from TAB rows")


# ─── adapter surface ─────────────────────────────────────────────────

def _extras_for(rev_dir: Path) -> dict:
    extras = {}
    for key, name in (("ch_master_xml", "TariffMasterData_v6.xml"),
                      ("ch_countries_xml", "CountryCodes_v3.xml"),
                      ("ch_base_xml", "TariffBaseMasterData_v2.xml"),
                      ("ch_tree_xml", "TariffsTree_v1.xml")):
        p = rev_dir / name
        if p.is_file():
            extras[key] = str(p)
    return extras


def resolve(spec: dict, args) -> AcquireResult:
    opts = (spec.get("acquire") or {})
    directory = Path(opts.get("manual_dir", str(SOURCE_DIR)))
    prefix = opts.get("manual_prefix", "ch_tariff")

    class _A:
        source = getattr(args, "source", None)
        revision = getattr(args, "revision", None)
        effective_date = getattr(args, "effective_date", None)

    if not _A.effective_date and not _A.source:
        candidates = sorted(
            (p for p in directory.glob(f"{prefix}_*_rev_*.csv")
             if not re.search(r"\.(de|fr|it)\.csv$", p.name)),
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
    spec_manual["acquire"] = {"options": {"dir": str(directory),
                                          "prefix": prefix}}
    res = _manual.resolve(spec_manual, _A)
    state = load_state()
    if state.get("cache_dir"):
        res.extras.update(_extras_for(Path(state["cache_dir"])))
    return res


def fetch(spec: dict, args) -> AcquireResult:
    session = _session()
    opts = (spec.get("acquire") or {}).get("options") or {}
    dest_template = opts.get(
        "dest", "data/ch_tariff_source/ch_tariff_{year}_rev_{number}.csv")

    upstream = getattr(args, "upstream_extras", None) or {}
    mode = upstream.get("mode", "full")
    etags = head_etags(session)
    state = load_state()

    # Download whatever changed (ETag-gated); everything lands in one dated
    # cache dir so a run's inputs are self-consistent.
    stamp = _dt.date.today().isoformat()
    rev_dir = CACHE_DIR / stamp
    prev_dir = Path(state.get("cache_dir", "")) if state.get("cache_dir") else None
    manifest = {"files": {}}
    for stem in REQUIRED:
        prev_etag = (state.get("etags") or {}).get(stem)
        prev_xml = (prev_dir / f"{stem}.xml") if prev_dir else None
        if (prev_etag == etags[stem]["etag"] and prev_xml
                and prev_xml.is_file()):
            rev_dir.mkdir(parents=True, exist_ok=True)
            target = rev_dir / f"{stem}.xml"
            if not target.is_file():
                target.write_bytes(prev_xml.read_bytes())
                for ext in (".xsd",):
                    src = prev_dir / f"{stem}{ext}"
                    if src.is_file():
                        (rev_dir / f"{stem}{ext}").write_bytes(src.read_bytes())
            print(f"[acquire:ch_tares] {stem}: unchanged (ETag), reusing cache")
        else:
            print(f"[acquire:ch_tares] downloading {stem} (.zip + .xsd)")
            download_pair(session, stem, rev_dir)
        xml_path = rev_dir / f"{stem}.xml"
        xsd_path = rev_dir / f"{stem}.xsd"
        xsd_sha = _sha256(xsd_path) if xsd_path.is_file() else ""
        prev_xsd = (state.get("xsd_sha") or {}).get(stem)
        if prev_xsd and xsd_sha and prev_xsd != xsd_sha:
            raise SystemExit(
                f"ERROR: {stem}.xsd CONTENT changed (schema generation "
                f"drift). Review the new schema and update the parser "
                f"before promoting — never parse a new schema with the old "
                f"assumptions. (Clear xsd_sha in state.json to accept.)")
        manifest["files"][stem] = {
            "etag": etags[stem]["etag"],
            "last_modified": etags[stem]["last_modified"],
            "sha256": _sha256(xml_path),
            "created": xml_created(xml_path),
            "xsd_sha256": xsd_sha,
        }

    master_created = manifest["files"]["TariffMasterData_v6"]["created"]
    year, num, effective = rev_from_created(master_created)

    if mode == "rates_only":
        rev_id = state.get("corpus_revision")
        if not rev_id:
            raise SystemExit("ERROR: rates_only refresh but state.json has "
                             "no corpus_revision — run a full rollout first")
        c_year, c_num = int(rev_id[:4]), int(rev_id.split("_rev_")[1])
        dest = Path(dest_template.format(year=c_year, number=c_num))
        if not dest.is_file():
            raise SystemExit(f"ERROR: rates_only refresh but {dest} is "
                             f"missing — run a full rollout first")
        effective_out = state.get("corpus_effective", effective)
        year_out, num_out = c_year, c_num
    else:
        rev_id = f"{year}_rev_{num}"
        dest = Path(dest_template.format(year=year, number=num))
        convert(rev_dir / "TariffsTree_v1.xml", dest)
        make_ch_chapters(rev_dir / "TariffsTree_v1.xml",
                         Path("scripts/hts_automation/chapters_ch.json"))
        state["corpus_revision"] = rev_id
        state["corpus_effective"] = effective
        state["classification_hash"] = classification_hash(
            rev_dir / "TariffsTree_v1.xml")
        effective_out, year_out, num_out = effective, year, num

    state["etags"] = {s: etags[s]["etag"] for s in REQUIRED}
    state["xsd_sha"] = {s: manifest["files"][s]["xsd_sha256"]
                        for s in REQUIRED}
    state["cache_dir"] = str(rev_dir)
    state["rates_created"] = master_created
    save_state(state)
    (rev_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    d = _dt.date.fromisoformat(effective_out)
    return AcquireResult(
        rev_id=rev_id, year=year_out, rev_num=num_out,
        effective_date=effective_out,
        effective_date_label=(f"{d.strftime('%B')} {d.day}, {d.year} "
                              f"Swiss tariff (master data {master_created[:10]})"),
        source_csv=str(dest),
        source_url=f"{HOST}/TariffMasterData_v6.zip",
        source_sha256=_sha256(dest),
        acquired_at=_dt.datetime.now(_dt.timezone.utc).isoformat(),
        extras={**_extras_for(rev_dir),
                "ch_master_created": master_created},
    )


def check_latest(spec: dict, args):
    """Three-outcome gate (module docstring). ETag HEADs only; the tree is
    downloaded for hashing ONLY when its ETag moved."""
    from check_upstream import UpstreamCheck

    session = _session()
    etags = head_etags(session)
    state = load_state()
    prev = state.get("etags") or {}
    changed = [s for s in REQUIRED if prev.get(s) != etags[s]["etag"]]

    def _standing(detail, mode):
        rev = state.get("corpus_revision")
        return UpstreamCheck(
            status="available", rev_id=rev,
            year=int(rev[:4]) if rev else None,
            rev_num=int(rev.split("_rev_")[1]) if rev else None,
            effective_date=state.get("corpus_effective", ""),
            detail=detail, extras={"mode": mode})

    if not prev or not state.get("corpus_revision"):
        # First run: everything is new.
        return UpstreamCheck(status="available", rev_id=None,
                             year=_dt.date.today().year, rev_num=0,
                             effective_date="",
                             detail="first Swiss acquisition",
                             extras={"mode": "full"})
    if not changed:
        return _standing("all BAZG master-data ETags unchanged", "full")
        # (mode full + rev==registered -> the generic gate skips cleanly)
    if TREE not in changed:
        return _standing(
            f"master data regenerated ({', '.join(changed)}) but the "
            f"TariffsTree is unchanged — duty measures refresh only",
            "rates_only")
    # Tree moved: hash its classification fields before deciding.
    rev_dir = CACHE_DIR / f"check-{_dt.date.today().isoformat()}"
    xml_path = download_pair(session, TREE, rev_dir)
    new_hash = classification_hash(xml_path)
    if new_hash == state.get("classification_hash"):
        return _standing(
            "TariffsTree ETag moved but classification fields are "
            "unchanged — duty measures refresh only", "rates_only")
    today = _dt.date.today()
    return UpstreamCheck(
        status="available", rev_id=f"{today.year}_rev_{today.month * 100 + today.day}",
        year=today.year, rev_num=today.month * 100 + today.day,
        effective_date=today.isoformat(),
        detail="TariffsTree nomenclature changed (classification hash "
               "differs) — full rollout",
        extras={"mode": "full"})


def _cli(argv=None) -> int:
    import argparse
    p = argparse.ArgumentParser(description="Swiss tariff adapter utilities")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert")
    c.add_argument("--tree", required=True, type=Path)
    c.add_argument("--out", required=True, type=Path)
    ch = sub.add_parser("chapters")
    ch.add_argument("--tree", required=True, type=Path)
    ch.add_argument("--out", required=True, type=Path)
    h = sub.add_parser("hash")
    h.add_argument("--tree", required=True, type=Path)
    args = p.parse_args(argv)
    if args.cmd == "convert":
        convert(args.tree, args.out)
    elif args.cmd == "chapters":
        make_ch_chapters(args.tree, args.out)
    elif args.cmd == "hash":
        print(classification_hash(args.tree))
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
