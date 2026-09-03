"""Taiwan (TW) — Customs Import Tariff via the Taiwan Customs portal.

SOURCES (portal.sw.nat.gov.tw, "Tariff Database Search System" download
pages GC453 [EN] / GC413 [full, Chinese]) — all live-verified 2026-09-03:

  海關進口稅則資料{YYYY}.xls   MAIN file: one sheet, one row per 11-digit
      CCC code (貨品分類號列 = 8-digit tariff no + 2 statistical + 1 check
      digit), BILINGUAL per row (中文貨名 + 英文貨名), duty Columns
      第一欄/第二欄/第三欄 (I = WTO/applied, II = preferential with embedded
      origin lists like "0% (PA,GT,NI,SV,HN,NZ,SG)", III = general), stat
      units, levy rules (稽徵規定) and import/export regulation codes.
  note_8_E.txt / note_8_C.txt   hierarchy 2..8 digits, variable depth
      (2 chapter / 4 heading / 5 dash-intermediate "01012 ─馬︰" / 6
      subheading / 8 tariff number) + S01..S21 section titles at the tail —
      BOTH languages ship from the portal, no curation needed.
  note_10_E.txt                 10-digit statistical lines (= 11-digit CCC
      minus the check digit) — reconciliation source.
  逐年降稅清表_0101/_0701.xls   forward-dated staged Column I/II/III cuts
      (8-digit level; supplementary — the main xls carries current rates).
  機動稅率清表.xls              provisional adjusted rates; 0 bytes when
      none are active.

ACCESS: downloads go through /APGQ/Download?fileName=<name>; the main xls
name gets the CURRENT YEAR appended (the page's own linkClick() does this).
The endpoint intermittently answers a 283-byte text/html "Logout" stub when
the request carries no session — the fix is a cookie-establishing GET of
the GC453 page first plus a Referer header (verified live from a non-TW
IP). A persistent stub or an unreachable portal (the portal is known to
geo-restrict at times) is NOT an error for the nightly: check_latest
reports a clean `in_progress` skip and the next reachable run — or a local
refresh — catches up. `TW_PORTAL_PROXY` (or standard HTTPS_PROXY) is
honored for a Taiwan egress proxy should a hard geo-wall ever appear.

REVISION MAPPING: the GC453 page prints "CCC CODE last modify date
YYYY-MM-DD" → rev_id = {year}_rev_{MMDD} (e.g. 2026-07-29 → 2026_rev_729);
sha256 of the main xls is the final change arbiter (state.json).

CANONICAL tw CSV (per language: base = EN, .zh sibling = Traditional
Chinese): same columns as kr — GOODS_CODE (variable length 2..11, as
published, never padded), SUFFIX 80, INDENT = longest-existing-prefix
chain depth, DESCRIPTION, UNIT (stat qty unit on 11-digit rows), IS_LEAF
(1 on 11-digit rows), START_DATE (unused, blank).

Requires xlrd (legacy BIFF .xls; pure-Python).
"""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

import requests

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from acquire import AcquireResult
    from acquire import manual as _manual
else:
    from . import AcquireResult
    from . import manual as _manual

PORTAL = "https://portal.sw.nat.gov.tw"
PAGE_EN = f"{PORTAL}/APGQ/GC453"
PAGE_FULL = f"{PORTAL}/APGQ/GC413"
DOWNLOAD = f"{PORTAL}/APGQ/Download"
SOURCE_DIR = Path("data/tw_tariff_source")
CACHE_DIR = SOURCE_DIR / ".tw_download"
STATE_PATH = SOURCE_DIR / "state.json"

MAIN_XLS = "海關進口稅則資料{year}.xls"
FILES = ("note_8_E.txt", "note_8_C.txt", "note_10_E.txt")

_LAST_MODIFY_RE = re.compile(r"CCC\s+CODE\s+last\s+modify\s+date\s*(?:</?[^>]*>|&nbsp;|\s)*(\d{4}-\d{2}-\d{2})", re.I)


def _session() -> requests.Session:
    s = requests.Session()
    s.headers["User-Agent"] = ("Mozilla/5.0 (X11; Linux x86_64) "
                               "AppleWebKit/537.36 Chrome/128.0 Safari/537.36")
    proxy = os.environ.get("TW_PORTAL_PROXY")
    if proxy:
        s.proxies.update({"http": proxy, "https": proxy})
    return s


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_state() -> dict:
    if STATE_PATH.is_file():
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    return {}


def save_state(state: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2, sort_keys=True,
                                     ensure_ascii=False) + "\n",
                          encoding="utf-8")


class PortalBlocked(RuntimeError):
    """Portal unreachable, geo-blocked, or persistently serving the logout
    stub — a network condition, not a data signal."""


def fetch_page(session: requests.Session) -> str:
    """GET the GC453 page: establishes the session cookies every download
    needs, and carries the 'CCC CODE last modify date' version signal.

    On 403 (the portal hard-blocks some cloud IP ranges — GitHub's runners
    among them), retry once with the stock requests User-Agent before giving
    up: the USITC static host showed the inverse pattern (browser UAs
    blocked, tool UAs allowed), so the cheap second attempt is worth it."""
    try:
        resp = session.get(PAGE_EN, timeout=60)
        resp.raise_for_status()
    except requests.HTTPError as exc:
        if exc.response is not None and exc.response.status_code == 403:
            try:
                resp = session.get(PAGE_EN, timeout=60,
                                   headers={"User-Agent": requests.utils.default_user_agent()})
                resp.raise_for_status()
                return resp.text
            except requests.RequestException:
                pass
        raise PortalBlocked(f"GC453 unreachable: {exc}") from exc
    except requests.RequestException as exc:
        raise PortalBlocked(f"GC453 unreachable: {exc}") from exc
    return resp.text


def last_modify_date(page_html: str) -> str:
    m = _LAST_MODIFY_RE.search(page_html)
    if not m:
        raise SystemExit("ERROR: GC453 page has no 'CCC CODE last modify "
                         "date' — page layout changed; refusing to guess "
                         "the revision.")
    return m.group(1)  # YYYY-MM-DD


def _looks_like_stub(resp: requests.Response) -> bool:
    ctype = resp.headers.get("Content-Type", "")
    return "text/html" in ctype.lower() or len(resp.content) < 1024


def download(session: requests.Session, name: str, dest: Path,
             _retried: bool = False) -> None:
    """Download one file; on the sessionless 'Logout' stub, re-establish the
    session ONCE and retry. A second stub raises PortalBlocked."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        resp = session.get(DOWNLOAD, params={"fileName": name},
                           headers={"Referer": PAGE_EN}, timeout=180)
        resp.raise_for_status()
    except requests.RequestException as exc:
        raise PortalBlocked(f"download {name!r} failed: {exc}") from exc
    if _looks_like_stub(resp):
        if _retried:
            raise PortalBlocked(
                f"download {name!r} keeps answering the logout stub "
                f"({len(resp.content)}B {resp.headers.get('Content-Type')}) — "
                f"session-gated or geo-blocked from this network")
        time.sleep(2)
        fetch_page(session)   # re-establish cookies
        return download(session, name, dest, _retried=True)
    dest.write_bytes(resp.content)
    print(f"[tw_customs] downloaded {name} -> {dest} ({len(resp.content):,}B)")


# ─── Parsing ─────────────────────────────────────────────────────────

# note_8 layout: fixed HS_NO column (9 chars) then the description; CRLF;
# UTF-8 in both language variants. Dash markers (─ / -) prefix the
# intermediate one-dash levels; they are presentation, not content.
_DASH_PREFIX = re.compile(r"^[─—\-–]+\s*")


def parse_note8(path: Path) -> tuple[list[dict], dict[str, str]]:
    """-> ([{code, desc}...] in file order, {S01: section title, ...}).
    Codes are 2/4/5/6/8 digits, as published."""
    nodes: list[dict] = []
    sections: dict[str, str] = {}
    last_section: str | None = None
    with path.open(encoding="utf-8", errors="strict", newline="") as fh:
        for i, line in enumerate(fh):
            line = line.rstrip("\r\n")
            if not line.strip() or i == 0:      # header: HS_NO     NOTE
                continue
            key, desc = line[:9].strip(), line[9:].strip()
            if re.fullmatch(r"S\d{2}", key):
                sections[key] = desc
                last_section = key
                continue
            if re.fullmatch(r"\d{2,8}", key):
                nodes.append({"code": key,
                              "desc": _DASH_PREFIX.sub("", desc).strip()})
                last_section = None
                continue
            # Long descriptions WRAP onto codeless continuation lines
            # (e.g. 293153's "…phenyl]" / "methylphosphonothionate").
            cont = line.strip()
            if last_section is not None:
                sections[last_section] = f"{sections[last_section]} {cont}".strip()
            elif nodes:
                nodes[-1]["desc"] = f"{nodes[-1]['desc']} {cont}".strip()
            else:
                raise SystemExit(f"ERROR: {path.name}:{i+1}: unexpected "
                                 f"HS_NO {key!r} — file layout changed")
    if not sections:
        raise SystemExit(f"ERROR: {path.name} has no S01..S21 section rows — "
                         f"file layout changed")
    return nodes, sections


MAIN_COLUMNS = ["貨品分類號列", "中文貨名", "英文貨名", "第一欄稅率",
                "第二欄稅率", "第三欄稅率", "統計數量單位", "統計重量單位",
                "稽徵規定", "輸入規定", "輸出規定"]


def parse_main_xls(path: Path) -> list[dict]:
    """MAIN xls -> one dict per 11-digit CCC row (verbatim strings).
    Header tripwire: refuses to guess if the column set changes."""
    import xlrd  # legacy BIFF; deliberate import-at-use (heavy)
    wb = xlrd.open_workbook(str(path))
    sh = wb.sheet_by_index(0)
    header = [str(sh.cell_value(0, c)).strip() for c in range(sh.ncols)]
    if header != MAIN_COLUMNS:
        raise SystemExit(f"ERROR: {path.name} header changed: {header} — "
                         f"expected {MAIN_COLUMNS}; refusing to guess")
    rows = []
    for r in range(1, sh.nrows):
        code = str(sh.cell_value(r, 0)).strip()
        if not code:
            continue
        if not re.fullmatch(r"\d{11}", code):
            raise SystemExit(f"ERROR: {path.name} row {r+1}: CCC code "
                             f"{code!r} is not 11 digits")
        rows.append({
            "code": code,
            "zh": str(sh.cell_value(r, 1)).strip(),
            "en": str(sh.cell_value(r, 2)).strip(),
            "col1": str(sh.cell_value(r, 3)).strip(),
            "col2": str(sh.cell_value(r, 4)).strip(),
            "col3": str(sh.cell_value(r, 5)).strip(),
            "unit_qty": str(sh.cell_value(r, 6)).strip(),
            "unit_wt": str(sh.cell_value(r, 7)).strip(),
            "levy": str(sh.cell_value(r, 8)).strip(),
            "import_reg": str(sh.cell_value(r, 9)).strip(),
            "export_reg": str(sh.cell_value(r, 10)).strip(),
        })
    return rows


def parse_note10_codes(path: Path) -> set[str]:
    """note_10 -> the set of 10-digit statistical codes (reconciliation)."""
    codes = set()
    with path.open(encoding="utf-8", newline="") as fh:
        for i, line in enumerate(fh):
            if i == 0:
                continue
            key = line[:11].strip()
            if re.fullmatch(r"\d{10}", key):
                codes.add(key)
    return codes


def convert(main_xls: Path, note8_en: Path, note8_zh: Path,
            out_csv: Path, note10_en: Path | None = None) -> dict:
    """note_8 tree (EN+ZH) + main-xls 11-digit leaves -> canonical tw CSVs
    (EN base + .zh sibling) in pre-order with longest-prefix parents.
    Reconciliation exceptions are reported, never silently resolved."""
    nodes_en, _sections = parse_note8(note8_en)
    nodes_zh, _sections_zh = parse_note8(note8_zh)
    leaves = parse_main_xls(main_xls)

    zh_by_code = {n["code"]: n["desc"] for n in nodes_zh}
    by_code: dict[str, dict] = {}
    for n in nodes_en:
        if n["code"] in by_code:
            raise SystemExit(f"ERROR: duplicate code {n['code']} in "
                             f"{note8_en.name}")
        by_code[n["code"]] = {"en": n["desc"],
                              "zh": zh_by_code.get(n["code"], ""),
                              "unit": ""}
    en_only = [c for c, v in by_code.items() if not v["zh"]]
    zh_only = sorted(set(zh_by_code) - set(by_code))
    if en_only:
        print(f"[tw_customs] RECONCILE: {len(en_only)} tree codes missing a "
              f"Chinese name (first: {en_only[:5]})")
    if zh_only:
        print(f"[tw_customs] RECONCILE: {len(zh_only)} Chinese tree codes "
              f"absent from the English tree (first: {zh_only[:5]})")

    for leaf in leaves:
        code = leaf["code"]
        if code in by_code:
            raise SystemExit(f"ERROR: 11-digit code {code} collides with a "
                             f"tree code")
        by_code[code] = {"en": leaf["en"], "zh": leaf["zh"],
                         "unit": leaf["unit_qty"] or leaf["unit_wt"]}

    def parent_of(code: str) -> str | None:
        for ln in range(len(code) - 1, 1, -1):
            if code[:ln] in by_code:
                return code[:ln]
        return None

    children: dict[str, list[str]] = {}
    roots: list[str] = []
    orphans = []
    for code in by_code:
        p = parent_of(code)
        if p is None:
            if len(code) != 2:
                orphans.append(code)
                continue
            roots.append(code)
        else:
            children.setdefault(p, []).append(code)
    if orphans:
        raise SystemExit(f"ERROR: {len(orphans)} non-chapter codes have no "
                         f"ancestor in the tree (first: {orphans[:5]})")

    # Reconciliation: xls 11-digit universe vs note_10 statistical codes
    # (11-digit minus check digit).
    stats = {"rows": 0, "leaves": len(leaves),
             "only_in_xls": 0, "only_in_note10": 0}
    if note10_en and note10_en.is_file():
        n10 = parse_note10_codes(note10_en)
        xls10 = {l["code"][:10] for l in leaves}
        only_xls = sorted(xls10 - n10)
        only_n10 = sorted(n10 - xls10)
        stats["only_in_xls"] = len(only_xls)
        stats["only_in_note10"] = len(only_n10)
        if only_xls:
            print(f"[tw_customs] RECONCILE: {len(only_xls)} xls statistical "
                  f"codes absent from note_10 (first: {only_xls[:5]})")
        if only_n10:
            print(f"[tw_customs] RECONCILE: {len(only_n10)} note_10 codes "
                  f"absent from the xls (first: {only_n10[:5]})")

    fields = ["GOODS_CODE", "SUFFIX", "INDENT", "DESCRIPTION", "UNIT",
              "IS_LEAF", "START_DATE"]
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    outs = {}
    for lang in ("en", "zh"):
        path = out_csv if lang == "en" else Path(f"{out_csv.with_suffix('')}.zh.csv")
        outs[lang] = (path, path.open("w", newline="", encoding="utf-8"))
    writers = {lang: csv.DictWriter(fh, fieldnames=fields)
               for lang, (_p, fh) in outs.items()}
    for w in writers.values():
        w.writeheader()

    def emit(code: str, depth: int) -> None:
        n = by_code[code]
        is_leaf = "1" if len(code) == 11 else "0"
        for lang in ("en", "zh"):
            desc = n[lang] or n["zh" if lang == "en" else "en"]
            writers[lang].writerow({
                "GOODS_CODE": code, "SUFFIX": "80", "INDENT": depth,
                "DESCRIPTION": desc,
                "UNIT": n["unit"] if is_leaf == "1" else "",
                "IS_LEAF": is_leaf, "START_DATE": "",
            })
        stats["rows"] += 1
        for kid in sorted(children.get(code, ())):
            emit(kid, depth + 1)

    sys.setrecursionlimit(10000)
    for root in sorted(roots):
        emit(root, 0)
    for _p, fh in outs.values():
        fh.close()
    print(f"[tw_customs] {out_csv} (+.zh): {stats['rows']:,} rows, "
          f"{stats['leaves']:,} CCC-11 leaves "
          f"(reconcile: {stats['only_in_xls']} xls-only / "
          f"{stats['only_in_note10']} note10-only)")
    return stats


_ROMAN = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
          "XI", "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII", "XIX",
          "XX", "XXI"]

# Standard HS section -> chapter spans (TW follows them; ch98 = TW's
# special-classification chapter, grouped under section XXI's successor
# span the way the Explorer expects an owning section for every chapter —
# it rides section XXI like other jurisdictions' trailing chapters).
_SECTION_SPANS = [("01", "05"), ("06", "14"), ("15", "15"), ("16", "24"),
                  ("25", "27"), ("28", "38"), ("39", "40"), ("41", "43"),
                  ("44", "46"), ("47", "49"), ("50", "63"), ("64", "67"),
                  ("68", "70"), ("71", "71"), ("72", "83"), ("84", "85"),
                  ("86", "89"), ("90", "92"), ("93", "93"), ("94", "96"),
                  ("97", "98")]


def make_tw_chapters(note8_en: Path, note8_zh: Path,
                     out_json: Path, out_json_zh: Path) -> None:
    """Chapters + sections for the corpus/Explorer in the shared chapters
    format ([{chapter, description, section, sectionTitle}...]), BOTH
    languages from the portal's own files (S01..S21 tails) — no curated
    section titles needed."""
    import unicodedata

    def section_for(chapter: str) -> int:
        for idx, (lo, hi) in enumerate(_SECTION_SPANS):
            if lo <= chapter <= hi:
                return idx + 1
        raise SystemExit(f"ERROR: chapter {chapter} outside every known "
                         f"section span")

    def build(path: Path, english: bool) -> list[dict]:
        nodes, sections = parse_note8(path)
        titles = {}
        for skey, raw in sections.items():
            # EN: "SECTION I LIVE ANIMALS; ..."; ZH: "第１類　活動物；…" —
            # strip the section label, keep the title. NFKC only for EN:
            # it would fold the fullwidth Chinese punctuation (；、) that
            # belongs in the ZH display.
            t = unicodedata.normalize("NFKC", raw) if english else raw
            t = re.sub(r"^(SECTION\s+[IVX]+\s*|第\s*[0-9０-９]+\s*類\s*)", "",
                       t, flags=re.I).strip()
            if english:
                t = t.capitalize()
            titles[int(skey[1:])] = t
        out = []
        for n in nodes:
            if len(n["code"]) != 2:
                continue
            raw_desc = unicodedata.normalize("NFKC", n["desc"]) if english else n["desc"]
            desc = re.sub(r"^(Chapter\s+\d+\s*|第\s*[0-9０-９]+\s*章\s*)", "",
                          raw_desc).strip()
            if english and desc:
                desc = desc[0].upper() + desc[1:]
            snum = section_for(n["code"])
            out.append({"chapter": n["code"], "description": desc,
                        "section": _ROMAN[snum - 1],
                        "sectionTitle": titles.get(snum, "")})
        return out

    for src, dest, english in ((note8_en, out_json, True),
                               (note8_zh, out_json_zh, False)):
        payload = build(src, english)
        dest.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                        encoding="utf-8")
        print(f"[tw_customs] {dest}: {len(payload)} chapters")


# ─── Revision plumbing ───────────────────────────────────────────────

def _rev_from_modify_date(iso_date: str) -> tuple[str, int, int]:
    """'2026-07-29' -> ('2026_rev_729', 2026, 729)."""
    year, month, day = iso_date.split("-")
    num = int(month) * 100 + int(day)
    return f"{year}_rev_{num}", int(year), num


def _extras() -> dict:
    state = load_state()
    out = {}
    if state.get("main_xls"):
        out["tw_main_xls"] = state["main_xls"]
    return out


def resolve(spec: dict, args) -> AcquireResult:
    """Offline resolve from the staged canonical CSV, pre-filling the
    effective date from the registry or state.json (KR pattern: manual
    resolve refuses to guess a date, so we look one up first)."""
    opts = (spec.get("acquire") or {}).get("options") or {}
    directory = Path(opts.get("dir") or SOURCE_DIR)
    prefix = (spec.get("acquire") or {}).get("manual_prefix", "tw_tariff")

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
                    _A.effective_date = state.get("effective_date")

    spec_manual = dict(spec)
    spec_manual["acquire"] = {"options": {"dir": str(directory),
                                          "prefix": prefix}}
    res = _manual.resolve(spec_manual, _A)
    res.extras.update(_extras())
    return res


def fetch(spec: dict, args) -> AcquireResult:
    """Session-first download of the full TW dataset -> canonical CSVs +
    bilingual chapters + state.json."""
    import datetime as _dt

    session = _session()
    page = fetch_page(session)
    modify_date = last_modify_date(page)
    rev_id, year, num = _rev_from_modify_date(modify_date)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    main_name = MAIN_XLS.format(year=_dt.date.today().year)
    main_path = CACHE_DIR / "tw_main.xls"
    download(session, main_name, main_path)
    paths = {}
    for name in FILES:
        paths[name] = CACHE_DIR / name
        download(session, name, paths[name])

    out_csv = SOURCE_DIR / f"tw_tariff_{rev_id}.csv"
    convert(main_path, paths["note_8_E.txt"], paths["note_8_C.txt"],
            out_csv, note10_en=paths["note_10_E.txt"])

    here = Path(__file__).resolve().parents[1]
    make_tw_chapters(paths["note_8_E.txt"], paths["note_8_C.txt"],
                     here / "chapters_tw.json", here / "chapters_tw.zh.json")

    sha = _sha256(main_path)
    save_state({
        "corpus_revision": rev_id,
        "effective_date": modify_date,
        "effective_date_label": f"CCC amendment of {modify_date}",
        "last_modify_date": modify_date,
        "main_xls_sha256": sha,
        "main_xls": str(main_path),
    })
    return AcquireResult(
        rev_id=rev_id, year=year, rev_num=num,
        effective_date=modify_date,
        effective_date_label=f"CCC amendment of {modify_date}",
        source_csv=str(out_csv),
        source_url=PAGE_EN,
        source_sha256=sha,
        acquired_at=_dt.datetime.now(_dt.timezone.utc).isoformat(),
        extras=_extras(),
    )


def check_latest(spec: dict, args):
    """Three-outcome nightly gate: the GC453 last-modify date + main-xls
    sha vs state.json. Network trouble (geo-block, logout stub, timeout) is
    a clean in_progress skip, never a red run."""
    from check_upstream import UpstreamCheck

    session = _session()
    try:
        page = fetch_page(session)
    except PortalBlocked as exc:
        return UpstreamCheck(
            status="in_progress",
            detail=f"Taiwan portal unreachable from this network — "
                   f"skipping TW gate ({exc})")
    modify_date = last_modify_date(page)
    rev_id, year, num = _rev_from_modify_date(modify_date)
    state = load_state()

    if state.get("last_modify_date") == modify_date and state.get("corpus_revision"):
        # Unchanged: report the CURRENT revision as available — the gate's
        # registered-revision comparison then resolves to a clean skip
        # (KR pattern: the adapter reports what it sees, the caller decides).
        rev = state["corpus_revision"]
        return UpstreamCheck(
            status="available", rev_id=rev,
            year=int(rev[:4]), rev_num=int(rev.split("_rev_")[1]),
            effective_date=state.get("effective_date", ""),
            detail=f"CCC last-modify date unchanged ({modify_date})",
            extras={"mode": "full"})
    return UpstreamCheck(
        status="available", rev_id=rev_id, year=year, rev_num=num,
        effective_date=modify_date,
        detail=f"CCC amendment {modify_date} "
               f"(state has {state.get('last_modify_date') or 'nothing'})",
        extras={"mode": "full"})


def _cli(argv=None) -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Taiwan customs tariff adapter")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert")
    c.add_argument("main_xls"); c.add_argument("note8_en")
    c.add_argument("note8_zh"); c.add_argument("out_csv")
    c.add_argument("--note10", default=None)
    ch = sub.add_parser("chapters")
    ch.add_argument("note8_en"); ch.add_argument("note8_zh")
    ch.add_argument("out_json"); ch.add_argument("out_json_zh")
    sub.add_parser("check")
    ns = ap.parse_args(argv)
    if ns.cmd == "convert":
        convert(Path(ns.main_xls), Path(ns.note8_en), Path(ns.note8_zh),
                Path(ns.out_csv),
                note10_en=Path(ns.note10) if ns.note10 else None)
    elif ns.cmd == "chapters":
        make_tw_chapters(Path(ns.note8_en), Path(ns.note8_zh),
                         Path(ns.out_json), Path(ns.out_json_zh))
    elif ns.cmd == "check":
        chk = check_latest({}, None)
        print(chk)
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
