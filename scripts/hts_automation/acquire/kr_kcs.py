"""South Korea acquisition: KCS datasets on data.go.kr -> canonical kr CSVs.

Three official Korea Customs Service datasets:
  15130660  HS Code Unit-Level Item Names  — the tariff tree (5 sheets by
            level: 2/4/5+6/7+8+9/10 digits), Korean + English at every level.
            PRIMARY classification source.
  15049722  HS Code                        — 10-digit HSK master (validity,
            units, property codes). Validates/enriches the leaves.
  15051179  Tariff Schedule by Item Number — duty rates (one-to-many per
            HSK, 224 rate classes, two period sheets). PRIMARY duty source.

DOWNLOAD FLOW (the portal's button is JS; verified live 2026-09-02):
  GET the dataset page -> extract the uddi publicDataDetailPk from
  fn_fileDataDown(...) -> POST /tcs/dss/selectFileDataDownload.do (cookie
  session) -> the response carries the real atchFileId -> GET
  /cmm/cmm/fileDownload.do. /cmm/cmm/check-limit.json is consulted first;
  needCaptcha=true aborts loudly (rate-limited — retry later, never scrape
  around a captcha).

REVISION MAPPING: filenames are dated (관세청_HS부호 단위별 품목명_20260101).
rev_id = {year}_rev_{MMDD} from the HIERARCHY file's date — the corpus
revision. The rates file updates on its own cadence (…_20260211) and rides
coverage.as_of; the three-outcome gate (skip / rates_only / full) compares
the three catalog-metadata records against data/kr_tariff_source/state.json.

CANONICAL kr CSV (per language: base = EN, .ko sibling = Korean):
  GOODS_CODE  the code as published, VARIABLE length (2..10 digits) — the
              Korean nomenclature has real 5/7/9-digit intermediate levels,
              so codes are never zero-padded (padding would collide levels)
  SUFFIX      always 80 (every row is a real coded line)
  INDENT      longest-existing-shorter-prefix chain depth (never digit count)
  DESCRIPTION item name in the file's language
  UNIT        quantity unit code from the HS master (10-digit rows)
  IS_LEAF     1 on 10-digit rows
  START_DATE  master validity start (10-digit rows)
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
    from acquire._xlsx_lite import read_sheets
else:
    from . import AcquireResult
    from . import manual as _manual
    from ._xlsx_lite import read_sheets

PORTAL = "https://www.data.go.kr"
DATASETS = {"hierarchy": "15130660", "master": "15049722", "rates": "15051179"}
SOURCE_DIR = Path("data/kr_tariff_source")
CACHE_DIR = SOURCE_DIR / ".kr_download"
STATE_PATH = SOURCE_DIR / "state.json"

_UDDI_RE = re.compile(r"fn_fileDataDown\('(\d+)',\s*'(uddi:[a-z0-9-]+)'")
_DATE_RE = re.compile(r"_(\d{8})$")

HIER_SHEET_HEADER = {"B": "한글품목명", "C": "영문품목명"}


def _session():
    import requests
    s = requests.Session()
    s.headers["User-Agent"] = ("Mozilla/5.0 (X11; Linux x86_64) "
                               "AppleWebKit/537.36 Chrome/128.0 Safari/537.36")
    return s


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _excel_serial_to_iso(v: str) -> str:
    v = (v or "").strip()
    if not v:
        return ""
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
        return v
    if v.isdigit():
        return (_dt.date(1899, 12, 30) + _dt.timedelta(days=int(v))).isoformat()
    return ""


def load_state() -> dict:
    if STATE_PATH.is_file():
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    return {}


def save_state(state: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2, sort_keys=True,
                                     ensure_ascii=False) + "\n",
                          encoding="utf-8")


def fetch_metadata(session, dataset_id: str) -> dict:
    """schema.org catalog record: alternateName carries the dated filename."""
    resp = session.get(f"{PORTAL}/catalog/{dataset_id}/fileData.json",
                       timeout=60)
    resp.raise_for_status()
    meta = resp.json()
    alt = meta.get("alternateName") or ""
    m = _DATE_RE.search(alt)
    return {"alternateName": alt,
            "dateModified": meta.get("dateModified") or "",
            "file_date": m.group(1) if m else ""}


def download_dataset(session, dataset_id: str, dest: Path) -> None:
    """Page -> uddi -> selectFileDataDownload (real atchFileId) -> file."""
    page = session.get(f"{PORTAL}/data/{dataset_id}/fileData.do", timeout=120)
    page.raise_for_status()
    m = _UDDI_RE.search(page.text)
    if not m or m.group(1) != dataset_id:
        raise SystemExit(f"ERROR: could not extract the download uddi from "
                         f"dataset page {dataset_id} — portal changed?")
    uddi = m.group(2)
    limit = session.post(f"{PORTAL}/cmm/cmm/check-limit.json",
                         data={"atchFileId": uddi, "fileDetailSn": "1"},
                         headers={"X-Requested-With": "XMLHttpRequest"},
                         timeout=60)
    if limit.ok and limit.json().get("needCaptcha"):
        raise SystemExit(f"ERROR: data.go.kr download for {dataset_id} is "
                         f"captcha-gated (rate limited) — retry later; never "
                         f"scrape around a captcha.")
    resp = session.post(
        f"{PORTAL}/tcs/dss/selectFileDataDownload.do",
        data={"publicDataPk": dataset_id, "publicDataDetailPk": uddi,
              "atchFileId": "", "fileDetailSn": "1",
              "publicDataTyCode": "PR0051"},
        headers={"Referer": f"{PORTAL}/data/{dataset_id}/fileData.do",
                 "X-Requested-With": "XMLHttpRequest"},
        timeout=120)
    resp.raise_for_status()
    body = resp.json()
    atch = body.get("atchFileId")
    sn = body.get("fileDetailSn", "1")
    if not atch:
        raise SystemExit(f"ERROR: selectFileDataDownload returned no "
                         f"atchFileId for {dataset_id}: "
                         f"{str(body)[:300]}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with session.get(f"{PORTAL}/cmm/cmm/fileDownload.do",
                     params={"atchFileId": atch, "fileDetailSn": sn,
                             "dataNm": "x"},
                     timeout=900, stream=True) as dl:
        dl.raise_for_status()
        with dest.open("wb") as fh:
            for chunk in dl.iter_content(1 << 20):
                fh.write(chunk)
    if dest.stat().st_size < 10000:
        raise SystemExit(f"ERROR: download for {dataset_id} is suspiciously "
                         f"small ({dest.stat().st_size} B) — portal flow "
                         f"changed?")


# ─── hierarchy parse (shared by convert + chapters) ──────────────────

def parse_hierarchy(hier_xlsx: Path) -> list[dict]:
    """All 5 level-sheets merged: [{code, ko, en}], validated headers."""
    sheets = read_sheets(str(hier_xlsx))
    out: list[dict] = []
    for name, rows in sheets.items():
        if not rows:
            continue
        hdr = rows[0]
        if (hdr.get("B") or "") != HIER_SHEET_HEADER["B"] or \
                (hdr.get("C") or "") != HIER_SHEET_HEADER["C"]:
            raise SystemExit(f"ERROR: hierarchy sheet {name!r} header changed "
                             f"({ {k: hdr.get(k) for k in 'ABC'} }) — review "
                             f"before ingesting")
        for r in rows[1:]:
            code = (r.get("A") or "").strip()
            if not code:
                continue
            if not code.isdigit() or not 2 <= len(code) <= 10:
                raise SystemExit(f"ERROR: bad HSK code {code!r} in sheet "
                                 f"{name!r}")
            out.append({"code": code,
                        "ko": " ".join((r.get("B") or "").split()),
                        "en": " ".join((r.get("C") or "").split())})
    return out


def parse_master(master_xlsx: Path) -> dict[str, dict]:
    """Active 10-digit HSK rows: code -> {ko, en, unit, start}."""
    sheets = read_sheets(str(master_xlsx))
    rows = next(iter(sheets.values()))
    today = _dt.date.today().isoformat()
    out: dict[str, dict] = {}
    for r in rows[1:]:
        code = (r.get("A") or "").strip()
        if not re.fullmatch(r"\d{10}", code):
            continue
        end = _excel_serial_to_iso(r.get("C") or "")
        if end and end < today:
            continue
        out[code] = {"ko": " ".join((r.get("D") or "").split()),
                     "en": " ".join((r.get("E") or "").split()),
                     "unit": (r.get("J") or "").strip(),
                     "start": _excel_serial_to_iso(r.get("B") or "")}
    return out


def convert(hier_xlsx: Path, master_xlsx: Path, out_csv: Path) -> dict:
    """Hierarchy + master -> canonical kr CSVs (EN base + .ko sibling) in
    pre-order with longest-prefix parents. Reconciliation A<->B exceptions
    are reported, never silently resolved."""
    nodes = parse_hierarchy(hier_xlsx)
    master = parse_master(master_xlsx)

    by_code: dict[str, dict] = {}
    for n in nodes:
        if n["code"] in by_code:
            raise SystemExit(f"ERROR: duplicate HSK code {n['code']} across "
                             f"hierarchy sheets")
        by_code[n["code"]] = n

    def parent_of(code: str) -> str | None:
        for ln in range(len(code) - 1, 1, -1):
            if code[:ln] in by_code:
                return code[:ln]
        return None

    children: dict[str, list[str]] = {}
    roots: list[str] = []
    for code in by_code:
        p = parent_of(code)
        if p is None:
            if len(code) != 2:
                raise SystemExit(f"ERROR: non-chapter root {code!r} — the "
                                 f"hierarchy is missing its ancestors")
            roots.append(code)
        else:
            children.setdefault(p, []).append(code)

    # Reconciliation (spec §13): hierarchy 10-digit universe vs master.
    hier10 = {c for c in by_code if len(c) == 10}
    only_hier = sorted(hier10 - set(master))
    only_master = sorted(set(master) - hier10)
    stats = {"rows": 0, "leaves": len(hier10),
             "only_in_hierarchy": len(only_hier),
             "only_in_master": len(only_master)}
    if only_hier:
        print(f"[kr_kcs] RECONCILE: {len(only_hier)} 10-digit codes in the "
              f"hierarchy but not active in the HS master "
              f"(first: {only_hier[:5]})")
    if only_master:
        print(f"[kr_kcs] RECONCILE: {len(only_master)} active HS-master codes "
              f"absent from the hierarchy (first: {only_master[:5]})")

    fields = ["GOODS_CODE", "SUFFIX", "INDENT", "DESCRIPTION", "UNIT",
              "IS_LEAF", "START_DATE"]
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    outs = {}
    for lang in ("en", "ko"):
        path = out_csv if lang == "en" else Path(f"{out_csv.with_suffix('')}.ko.csv")
        outs[lang] = (path, path.open("w", newline="", encoding="utf-8"))
    writers = {lang: csv.DictWriter(fh, fieldnames=fields)
               for lang, (_p, fh) in outs.items()}
    for w in writers.values():
        w.writeheader()

    def emit(code: str, depth: int) -> None:
        n = by_code[code]
        is_leaf = "1" if len(code) == 10 else ""
        if len(code) == 10:
            is_leaf = "1"
        m = master.get(code, {})
        for lang in ("en", "ko"):
            desc = n[lang] or n["en" if lang == "ko" else "ko"]
            writers[lang].writerow({
                "GOODS_CODE": code, "SUFFIX": "80", "INDENT": depth,
                "DESCRIPTION": desc,
                "UNIT": m.get("unit", "") if len(code) == 10 else "",
                "IS_LEAF": "1" if len(code) == 10 else "0",
                "START_DATE": m.get("start", "") if len(code) == 10 else "",
            })
        stats["rows"] += 1
        for kid in sorted(children.get(code, ())):
            emit(kid, depth + 1)

    sys.setrecursionlimit(10000)
    for root in sorted(roots):
        emit(root, 0)
    for _p, fh in outs.values():
        fh.close()
    print(f"[kr_kcs] {out_csv} (+.ko): {stats['rows']:,} rows, "
          f"{stats['leaves']:,} HSK-10 leaves "
          f"(reconcile: {stats['only_in_hierarchy']} hier-only / "
          f"{stats['only_in_master']} master-only)")
    return stats


def make_kr_chapters(hier_xlsx: Path, out_json: Path,
                     sections_en: Path, sections_ko: Path) -> None:
    """chapters_kr.json (EN) + .ko.json from the HS2 sheet; sections from the
    curated EN/KO HS-section files."""
    nodes = [n for n in parse_hierarchy(hier_xlsx) if len(n["code"]) == 2]
    for lang, sections_path in (("en", sections_en), ("ko", sections_ko)):
        sections = json.loads(sections_path.read_text(encoding="utf-8"))
        chapters = []
        for n in sorted(nodes, key=lambda x: x["code"]):
            desc = n[lang] or n["en"]
            # The Korean chapter names carry a '제N류' prefix; keep it — it is
            # the official presentation.
            entry = {"chapter": n["code"], "description": desc}
            num = int(n["code"])
            for s in sections:
                if s["start"] <= num <= s["end"]:
                    entry["section"] = s["section"]
                    entry["sectionTitle"] = s["sectionTitle"]
                    break
            chapters.append(entry)
        dest = out_json if lang == "en" else Path(f"{out_json.with_suffix('')}.ko.json")
        dest.write_text(json.dumps(chapters, indent=2, ensure_ascii=False)
                        + "\n", encoding="utf-8")
    print(f"[kr_kcs] {out_json} (+.ko): {len(nodes)} chapters")


# ─── adapter surface ─────────────────────────────────────────────────

def _rev_from_file_date(file_date: str) -> tuple[str, int, int]:
    year = int(file_date[:4])
    num = int(file_date[4:8])          # MMDD as int, monotonic within a year
    return f"{year}_rev_{num}", year, num


def _extras() -> dict:
    extras = {}
    for key, name in (("kr_rates_xlsx", "rates.xlsx"),
                      ("kr_master_xlsx", "master.xlsx"),
                      ("kr_hier_xlsx", "hierarchy.xlsx")):
        p = CACHE_DIR / name
        if p.is_file():
            extras[key] = str(p)
    state = load_state()
    if state.get("rates_file_date"):
        extras["kr_rates_date"] = state["rates_file_date"]
    return extras


def resolve(spec: dict, args) -> AcquireResult:
    opts = (spec.get("acquire") or {})
    directory = Path(opts.get("manual_dir", str(SOURCE_DIR)))
    prefix = opts.get("manual_prefix", "kr_tariff")

    class _A:
        source = getattr(args, "source", None)
        revision = getattr(args, "revision", None)
        effective_date = getattr(args, "effective_date", None)

    if not _A.effective_date and not _A.source:
        candidates = sorted(
            (c for c in directory.glob(f"{prefix}_*_rev_*.csv")
             if re.fullmatch(rf"{re.escape(prefix)}_\d{{4}}_rev_\d+", c.stem)),
            key=lambda p: p.stat().st_mtime, reverse=True)
        if candidates:
            rev_id = candidates[0].stem.replace(f"{prefix}_", "")
            registry = spec.get("registry")
            if registry and Path(registry).is_file():
                for r in csv.DictReader(open(registry, encoding="utf-8")):
                    if r.get("revision") == rev_id:
                        _A.effective_date = r["effective_date"]
                        break
            if not _A.effective_date:
                state = load_state()
                if state.get("corpus_revision") == rev_id:
                    _A.effective_date = state.get("corpus_effective")

    spec_manual = dict(spec)
    spec_manual["acquire"] = {"options": {"dir": str(directory),
                                          "prefix": prefix}}
    res = _manual.resolve(spec_manual, _A)
    res.extras.update(_extras())
    return res


def fetch(spec: dict, args) -> AcquireResult:
    session = _session()
    opts = (spec.get("acquire") or {}).get("options") or {}
    dest_template = opts.get(
        "dest", "data/kr_tariff_source/kr_tariff_{year}_rev_{number}.csv")

    upstream = getattr(args, "upstream_extras", None) or {}
    mode = upstream.get("mode", "full")
    metas = upstream.get("metas") or {
        k: fetch_metadata(session, v) for k, v in DATASETS.items()}
    state = load_state()

    print(f"[acquire:kr_kcs] mode {mode}: hierarchy "
          f"{metas['hierarchy']['file_date']}, master "
          f"{metas['master']['file_date']}, rates {metas['rates']['file_date']}")
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    print("[acquire:kr_kcs] downloading rates (15051179, ~22 MB)")
    download_dataset(session, DATASETS["rates"], CACHE_DIR / "rates.xlsx")
    state["rates_file_date"] = metas["rates"]["file_date"]
    state["rates_modified"] = metas["rates"]["dateModified"]
    state["rates_sha256"] = _sha256(CACHE_DIR / "rates.xlsx")

    if mode == "rates_only":
        rev_id = state.get("corpus_revision")
        if not rev_id:
            raise SystemExit("ERROR: rates_only refresh but state.json has "
                             "no corpus_revision — run a full rollout first")
        year, num = int(rev_id[:4]), int(rev_id.split("_rev_")[1])
        dest = Path(dest_template.format(year=year, number=num))
        if not dest.is_file():
            raise SystemExit(f"ERROR: rates_only refresh but the corpus CSV "
                             f"{dest} is missing")
        effective = state.get("corpus_effective")
    else:
        print("[acquire:kr_kcs] downloading hierarchy (15130660) + "
              "master (15049722)")
        download_dataset(session, DATASETS["hierarchy"],
                         CACHE_DIR / "hierarchy.xlsx")
        download_dataset(session, DATASETS["master"], CACHE_DIR / "master.xlsx")
        rev_id, year, num = _rev_from_file_date(metas["hierarchy"]["file_date"])
        d = metas["hierarchy"]["file_date"]
        effective = f"{d[:4]}-{d[4:6]}-{d[6:8]}"
        dest = Path(dest_template.format(year=year, number=num))
        convert(CACHE_DIR / "hierarchy.xlsx", CACHE_DIR / "master.xlsx", dest)
        make_kr_chapters(
            CACHE_DIR / "hierarchy.xlsx",
            Path("scripts/hts_automation/chapters_kr.json"),
            Path("scripts/hts_automation/hs_sections.json"),
            Path("scripts/hts_automation/hs_sections.ko.json"))
        state["corpus_revision"] = rev_id
        state["corpus_effective"] = effective
        state["hierarchy_file_date"] = metas["hierarchy"]["file_date"]
        state["hierarchy_modified"] = metas["hierarchy"]["dateModified"]
        state["master_file_date"] = metas["master"]["file_date"]
        state["master_modified"] = metas["master"]["dateModified"]
        state["hierarchy_sha256"] = _sha256(CACHE_DIR / "hierarchy.xlsx")
    save_state(state)

    d = _dt.date.fromisoformat(effective)
    return AcquireResult(
        rev_id=rev_id, year=year, rev_num=num,
        effective_date=effective,
        effective_date_label=f"{d.strftime('%B')} {d.day}, {d.year}",
        source_csv=str(dest),
        source_url=f"{PORTAL}/data/{DATASETS['hierarchy']}/fileData.do",
        source_sha256=_sha256(dest),
        acquired_at=_dt.datetime.now(_dt.timezone.utc).isoformat(),
        extras=_extras(),
    )


def check_latest(spec: dict, args):
    """Three-outcome nightly gate: poll the three catalog-metadata records
    against state.json — classification datasets changed -> full rollout;
    only the rates dataset changed -> rates_only; nothing -> up to date."""
    from check_upstream import UpstreamCheck

    session = _session()
    metas = {k: fetch_metadata(session, v) for k, v in DATASETS.items()}
    state = load_state()

    def changed(name: str) -> bool:
        return (metas[name]["file_date"] != state.get(f"{name}_file_date")
                or metas[name]["dateModified"] != state.get(f"{name}_modified"))

    classification_changed = changed("hierarchy") or changed("master")
    rates_changed = changed("rates")
    rev_id, year, num = _rev_from_file_date(
        metas["hierarchy"]["file_date"] or "20000101")
    d = metas["hierarchy"]["file_date"]
    effective = f"{d[:4]}-{d[4:6]}-{d[6:8]}" if d else ""

    if classification_changed or not state.get("corpus_revision"):
        return UpstreamCheck(
            status="available", rev_id=rev_id, year=year, rev_num=num,
            effective_date=effective,
            detail=f"KCS classification dataset {d} (hierarchy/master changed)",
            extras={"mode": "full", "metas": metas})
    if rates_changed:
        rev = state["corpus_revision"]
        return UpstreamCheck(
            status="available", rev_id=rev,
            year=int(rev[:4]), rev_num=int(rev.split("_rev_")[1]),
            effective_date=metas["rates"]["dateModified"],
            detail=f"KCS rates dataset changed "
                   f"({metas['rates']['file_date']}) — duty refresh only",
            extras={"mode": "rates_only", "metas": metas})
    rev = state["corpus_revision"]
    return UpstreamCheck(
        status="available", rev_id=rev,
        year=int(rev[:4]), rev_num=int(rev.split("_rev_")[1]),
        effective_date=state.get("corpus_effective", ""),
        detail="KCS datasets unchanged",
        extras={"mode": "full", "metas": metas})


def _cli(argv=None) -> int:
    import argparse
    p = argparse.ArgumentParser(description="KR KCS adapter utilities")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert")
    c.add_argument("--hierarchy", required=True, type=Path)
    c.add_argument("--master", required=True, type=Path)
    c.add_argument("--out", required=True, type=Path)
    ch = sub.add_parser("chapters")
    ch.add_argument("--hierarchy", required=True, type=Path)
    ch.add_argument("--out", required=True, type=Path)
    ch.add_argument("--sections-en", required=True, type=Path)
    ch.add_argument("--sections-ko", required=True, type=Path)
    args = p.parse_args(argv)
    if args.cmd == "convert":
        convert(args.hierarchy, args.master, args.out)
    elif args.cmd == "chapters":
        make_kr_chapters(args.hierarchy, args.out,
                         args.sections_en, args.sections_ko)
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
