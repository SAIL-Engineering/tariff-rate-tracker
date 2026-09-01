"""UK acquisition: DBT Data API (uk-tariff-2021-01-01) -> canonical CSV.

  resolve()      OFFLINE: newest data/gb_tariff_source/gb_tariff_*_rev_*.csv,
                 effective date from the registry; extras re-hydrated from the
                 download cache when present.
  fetch()        resolve the latest concrete version via the API's `latest`
                 redirect, PIN it for every download (versions can change
                 daily; mixing `latest` mid-run could mix versions), then pull
                 commodities + measures-as-defined, stream-scan measures-on-
                 declarable (357 MB, never stored) for the declarable-sid
                 universe + reconciliation samples, and snapshot geographical-
                 area membership from the public UK Trade Tariff service API.
  check_latest() the nightly gate — two stages (see below).

REVISION MAPPING: versions are v4.0.<patch> with the patch increasing on
every (near-daily) republication. rev_id = {published_year}_rev_{patch}
(2026_rev_1591) — monotonic, integer, fits every existing constraint.

THE DAILY-VERSION PROBLEM: most version bumps change measures, not the
nomenclature. A new *corpus* revision (Pinecone publish + Supabase row) is
only warranted when the classification-relevant commodity fields change, so
check_latest computes a classification_hash over them (spec §44) and
compares against data/gb_tariff_source/state.json:
  hash changed            -> full rollout (new revision)
  version newer, hash same-> rates_only: rebuild + ship ONLY the duty
                             artifacts under the existing corpus revision
                             stem (coverage.as_of carries the measures
                             version); no Pinecone/Supabase/registry churn
  version == state        -> skip

CANONICAL CSV: the UK tariff is TARIC-descended — 10-digit zero-padded codes
and the same suffix semantics (80 = real line, 10..70 = grouping rows) — so
convert() emits the SAME canonical CSV as the EU adapter and the whole
source_format="taric" path (loader, explorer dataset, chapters, trimmed
display codes, ancestor-walk duty inheritance) is reused unchanged. INDENT is
the parent__sid chain depth (never code length — 3,107 codes share digits
across suffixes) and rows are emitted in pre-order so the indent-driven tree
builder sees parents before children. IS_LEAF comes from the declarable-sid
universe of measures-on-declarable-commodities — the dataset's own
authoritative "can actually be declared" set (suffix 80 alone is not proof).
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
else:
    from . import AcquireResult
    from . import manual as _manual

DATASET = "uk-tariff-2021-01-01"
API = f"https://data.api.trade.gov.uk/v1/datasets/{DATASET}"
TT_API = "https://www.trade-tariff.service.gov.uk/api/v2"
SOURCE_DIR = Path("data/gb_tariff_source")
CACHE_DIR = SOURCE_DIR / ".uk_download"
STATE_PATH = SOURCE_DIR / "state.json"

_VERSION_RE = re.compile(r"/versions/(v[\d.]+)/")
_PUBLISHED_RE = re.compile(r"Published on\s*(?:</[^>]+>)?\s*(?:<[^>]+>)?\s*"
                           r"(\d{1,2}\s+\w+\s+\d{4})", re.IGNORECASE)

COMMODITY_COLUMNS = [
    "id", "commodity__sid", "commodity__code", "commodity__suffix",
    "commodity__description", "commodity__validity_start",
    "commodity__validity_end", "parent__sid", "parent__code",
    "parent__suffix"]
MEASURE_COLUMNS = [
    "id", "commodity__sid", "commodity__code", "commodity__indent",
    "commodity__description", "measure__sid", "measure__type__id",
    "measure__type__description", "measure__additional_code__code",
    "measure__additional_code__description", "measure__duty_expression",
    "measure__effective_start_date", "measure__effective_end_date",
    "measure__reduction_indicator", "measure__footnotes",
    "measure__conditions", "measure__geographical_area__sid",
    "measure__geographical_area__id", "measure__geographical_area__description",
    "measure__excluded_geographical_areas__ids",
    "measure__excluded_geographical_areas__descriptions",
    "measure__quota__order_number", "measure__regulation__id",
    "measure__regulation__url"]

# Classification-relevant fields (spec §44): a change here means the corpus
# must be re-embedded; anything else is measures-only churn.
HASH_FIELDS = ("commodity__sid", "commodity__code", "commodity__suffix",
               "commodity__description", "commodity__validity_start",
               "commodity__validity_end", "parent__sid", "parent__code",
               "parent__suffix")

RECONCILE_SAMPLE_CAP = 600


def _session():
    import requests
    s = requests.Session()
    s.headers["User-Agent"] = "sail-tariff-tracker uk_tariff adapter"
    return s


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _na(value: str | None) -> str:
    v = (value or "").strip()
    return "" if v == "#NA" else v


def load_state() -> dict:
    if STATE_PATH.is_file():
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    return {}


def save_state(state: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n",
                          encoding="utf-8")


def resolve_latest_version(session) -> tuple[str, str]:
    """(version, published ISO date) via the `latest` redirect — spec §2."""
    resp = session.get(f"{API}/versions/latest/metadata?format=html",
                       timeout=60, allow_redirects=True)
    resp.raise_for_status()
    m = _VERSION_RE.search(resp.url)
    if not m:
        raise SystemExit(f"ERROR: could not extract a concrete version from "
                         f"the latest redirect ({resp.url}) — API changed?")
    version = m.group(1)
    pm = _PUBLISHED_RE.search(resp.text)
    if not pm:
        raise SystemExit("ERROR: version metadata HTML lacks a 'Published on' "
                         "date — cannot derive the effective date")
    published = _dt.datetime.strptime(pm.group(1), "%d %B %Y").date()
    return version, published.isoformat()


def version_patch(version: str) -> int:
    m = re.fullmatch(r"v[\d.]*?(\d+)", version)
    if not m:
        raise SystemExit(f"ERROR: unparseable UK dataset version {version!r}")
    return int(m.group(1))


def assert_csvw_schema(session, version: str) -> None:
    """Schema-change tripwire (spec §54): required columns must exist,
    verbatim, in the CSVW machine-readable dictionary."""
    resp = session.get(f"{API}/versions/{version}/metadata?format=csvw",
                       timeout=60)
    resp.raise_for_status()
    tables = {t.get("url", ""): [c.get("name") for c in
                                 t.get("tableSchema", {}).get("columns", [])]
              for t in resp.json().get("tables", [])}
    def cols_for(fragment):
        for url, cols in tables.items():
            if fragment in url and "format=csv" in url:
                return cols
        return None
    com = cols_for("commodities-report")
    mad = cols_for("measures-as-defined")
    if com != COMMODITY_COLUMNS:
        raise SystemExit(f"ERROR: commodities-report schema changed.\n"
                         f"  expected {COMMODITY_COLUMNS}\n  got      {com}\n"
                         f"Review the CSVW dictionary before ingesting.")
    if mad != MEASURE_COLUMNS:
        raise SystemExit(f"ERROR: measures-as-defined schema changed.\n"
                         f"  expected {MEASURE_COLUMNS}\n  got      {mad}\n"
                         f"Review the CSVW dictionary before ingesting.")


def _download(session, url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with session.get(url, timeout=600, stream=True) as resp:
        resp.raise_for_status()
        with dest.open("wb") as fh:
            for chunk in resp.iter_content(1 << 20):
                fh.write(chunk)


def download_commodities(session, version: str) -> Path:
    dest = CACHE_DIR / version / "commodities.csv"
    if not dest.is_file():
        _download(session,
                  f"{API}/versions/{version}/tables/commodities-report/data"
                  f"?format=csv&download", dest)
    return dest


def classification_hash(commodities_csv: Path) -> str:
    """Hash of the classification-relevant commodity fields, order-independent
    (rows sorted by sid) — spec §44's reindex-avoidance key."""
    with commodities_csv.open(newline="", encoding="utf-8-sig") as fh:
        rows = sorted(("\x1f".join(r.get(f, "") for f in HASH_FIELDS))
                      for r in csv.DictReader(fh))
    h = hashlib.sha256()
    for row in rows:
        h.update(row.encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()


# ─── convert: commodities -> canonical taric CSV ─────────────────────

def convert(commodities_csv: Path, declarable_sids: set[str],
            out_csv: Path) -> dict:
    """Emit the canonical CSV in pre-order (parents before children), with
    INDENT = parent-chain depth. Fails loudly on duplicate sids, missing or
    cyclic parents, or duplicate active (code, suffix) pairs."""
    with commodities_csv.open(newline="", encoding="utf-8-sig") as fh:
        raw = list(csv.DictReader(fh))

    today = _dt.date.today().isoformat()
    stats = {"rows": 0, "coded": 0, "conditions": 0, "leaves": 0,
             "end_dated_dropped": 0, "source_rows": len(raw)}
    nodes: dict[str, dict] = {}
    for r in raw:
        sid = r["commodity__sid"].strip()
        end = _na(r.get("commodity__validity_end"))
        if end and end < today:
            stats["end_dated_dropped"] += 1
            continue
        if sid in nodes:
            raise SystemExit(f"ERROR: duplicate commodity__sid {sid}")
        code = r["commodity__code"].strip()
        suffix = r["commodity__suffix"].strip()
        if not re.fullmatch(r"\d{10}", code):
            raise SystemExit(f"ERROR: commodity__code {code!r} is not 10 "
                             f"digits (sid {sid}) — leading zeros lost?")
        nodes[sid] = {
            "sid": sid, "code": code, "suffix": suffix,
            # Multi-line + shouted descriptions normalized exactly like the
            # EU convert ("|" is display_text's separator downstream).
            "desc": " ".join((r.get("commodity__description") or "")
                             .replace("|", " ").split()),
            "start": _na(r.get("commodity__validity_start")),
            "parent": _na(r.get("parent__sid")),
        }

    # The dataset carries superseded nodes that were never end-dated (e.g.
    # the 2207 ethanol lines republished 2023-09-16 with the 2019 nodes left
    # "active"). Keep the newest validity_start per (code, suffix); the
    # missing-parent assertion below still guards against dropping a node
    # something kept depends on.
    by_key: dict[tuple, list[str]] = {}
    for sid, n in nodes.items():
        by_key.setdefault((n["code"], n["suffix"]), []).append(sid)
    for key, sids in by_key.items():
        if len(sids) > 1:
            keep = max(sids, key=lambda s: (nodes[s]["start"], int(s)))
            for s_ in sids:
                if s_ != keep:
                    dropped = nodes.pop(s_)
                    stats["superseded_dropped"] =                         stats.get("superseded_dropped", 0) + 1
                    print(f"[uk_tariff] superseded node dropped: sid {s_} "
                          f"{key[0]}/{key[1]} (start {dropped['start']}; "
                          f"kept sid {keep}, start {nodes[keep]['start']})")

    children: dict[str, list[str]] = {}
    roots: list[str] = []
    for sid, n in nodes.items():
        p = n["parent"]
        if not p:
            roots.append(sid)
        elif p not in nodes:
            raise SystemExit(f"ERROR: sid {sid} references missing parent "
                             f"sid {p} — hierarchy is incomplete")
        else:
            children.setdefault(p, []).append(sid)

    seen80: dict[str, int] = {}
    rows_out: list[dict] = []

    def emit(sid: str, depth: int, seen: tuple) -> None:
        if sid in seen:
            raise SystemExit(f"ERROR: parent cycle at sid {sid}")
        n = nodes[sid]
        desc = n["desc"]
        if desc.isupper():
            desc = desc.capitalize()
        is_leaf = ""
        if n["suffix"] == "80":
            seen80[n["code"]] = seen80.get(n["code"], 0) + 1
            stats["coded"] += 1
            childless = sid not in children
            # The declarable universe (sids carrying measures) is the primary
            # leaf authority; a childless suffix-80 node outside it is still
            # a real terminal code (e.g. the 9930/9950 special-movement
            # provisions, which bear no measures) — counted for visibility.
            if n["sid"] in declarable_sids:
                is_leaf = "1"
                if not childless:
                    stats["declarable_with_children"] = \
                        stats.get("declarable_with_children", 0) + 1
                    print(f"[uk_tariff] WARNING: declarable sid {sid} "
                          f"({n['code']}) has children in the hierarchy")
            elif childless:
                is_leaf = "1"
                stats["leaves_without_measures"] = \
                    stats.get("leaves_without_measures", 0) + 1
            else:
                is_leaf = "0"
            if is_leaf == "1":
                stats["leaves"] += 1
        else:
            stats["conditions"] += 1
        rows_out.append({"GOODS_CODE": n["code"], "SUFFIX": n["suffix"],
                         "INDENT": depth, "DESCRIPTION": desc,
                         "IS_LEAF": is_leaf, "START_DATE": n["start"]})
        stats["rows"] += 1
        for kid in sorted(children.get(sid, ()),
                          key=lambda s: (nodes[s]["code"], nodes[s]["suffix"])):
            emit(kid, depth + 1, seen + (sid,))

    sys.setrecursionlimit(10000)
    for root in sorted(roots, key=lambda s: nodes[s]["code"]):
        emit(root, 0, ())

    dupes = {d: c for d, c in seen80.items() if c > 1}
    if dupes:
        raise SystemExit(f"ERROR: {len(dupes)} duplicate active suffix-80 "
                         f"codes, first 10: {sorted(dupes)[:10]}")

    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with out_csv.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["GOODS_CODE", "SUFFIX", "INDENT",
                                           "DESCRIPTION", "IS_LEAF",
                                           "START_DATE"])
        w.writeheader()
        w.writerows(rows_out)
    print(f"[uk_tariff] {out_csv}: {stats['rows']:,} rows "
          f"({stats['coded']:,} coded, {stats['conditions']:,} grouping, "
          f"{stats['leaves']:,} declarable leaves, "
          f"{stats['end_dated_dropped']:,} end-dated dropped)")
    return stats


# ─── declarable universe (streamed, 357 MB never stored) ─────────────

def stream_declarable(session, version: str, dest_json: Path) -> dict:
    """One pass over measures-on-declarable-commodities: the distinct
    commodity__sid universe (the authoritative 'can be declared' set) plus a
    deterministic sample of sid -> sorted measure__sid list used to reconcile
    the declared-level + ancestor-walk duty build against the dataset's own
    leaf expansion."""
    url = (f"{API}/versions/{version}/tables/"
           f"measures-on-declarable-commodities/data?format=csv&download")
    sids: set[str] = set()
    sample: dict[str, list[str]] = {}
    rows = 0
    # Spooled to disk rather than parsed off the socket: a 357 MB chunked
    # stream held open for minutes gets closed under our feet; the temp file
    # is deleted right after the single parse pass.
    tmp = dest_json.parent / ".declarable_stream.csv"
    _download(session, url, tmp)
    try:
        with tmp.open(newline="", encoding="utf-8-sig") as text:
            reader = csv.DictReader(text)
            if reader.fieldnames != MEASURE_COLUMNS:
                raise SystemExit("ERROR: measures-on-declarable-commodities "
                                 f"columns changed: {reader.fieldnames}")
            for r in reader:
                rows += 1
                sid = r["commodity__sid"]
                sids.add(sid)
                # Deterministic sample: spread over the sid space, capped.
                if (int(sid) % 41 == 0
                        and (sid in sample
                             or len(sample) < RECONCILE_SAMPLE_CAP)):
                    sample.setdefault(sid, []).append(r["measure__sid"])
    finally:
        tmp.unlink(missing_ok=True)
    out = {"version": version, "row_count": rows,
           "declarable_sids": sorted(sids),
           "sample_measures": {k: sorted(v) for k, v in sample.items()}}
    dest_json.parent.mkdir(parents=True, exist_ok=True)
    dest_json.write_text(json.dumps(out), encoding="utf-8")
    print(f"[uk_tariff] declarable universe: {len(sids):,} sids over "
          f"{rows:,} measure rows ({len(sample)} reconciliation samples)")
    return out


# ─── geographical areas (public UK Trade Tariff service API) ─────────

def fetch_geo_areas(session, dest_json: Path) -> dict:
    """The flattened CSVs name areas but not their members; the public
    trade-tariff service API lists all areas WITH children in one call
    (relationship ids are ISO codes directly — verified live)."""
    resp = session.get(f"{TT_API}/geographical_areas",
                       headers={"Accept": "application/json"}, timeout=120)
    resp.raise_for_status()
    areas = {}
    for a in resp.json().get("data", []):
        attrs = a.get("attributes", {})
        members = [c["id"] for c in (a.get("relationships", {})
                                     .get("children_geographical_areas", {})
                                     .get("data", []) or [])]
        areas[attrs.get("id") or a["id"]] = {
            "description": attrs.get("description", ""),
            "members": sorted(members),
        }
    if "1011" not in areas or "1013" not in areas:
        raise SystemExit("ERROR: geographical areas response lacks 1011/1013 "
                         "— trade-tariff API changed?")
    out = {"fetched_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
           "areas": areas}
    dest_json.parent.mkdir(parents=True, exist_ok=True)
    dest_json.write_text(json.dumps(out, sort_keys=True), encoding="utf-8")
    print(f"[uk_tariff] geographical areas: {len(areas)} "
          f"(ERGA OMNES {len(areas['1011']['members'])} members, "
          f"EU {len(areas['1013']['members'])})")
    return out


# ─── adapter surface ─────────────────────────────────────────────────

def _extras_for(version: str) -> dict:
    vdir = CACHE_DIR / version
    extras = {"gb_version": version}
    for key, name in (("gb_measures_csv", "measures_as_defined.csv"),
                      ("gb_geo_json", "geo_areas.json"),
                      ("gb_declarable_json", "declarable.json")):
        p = vdir / name
        if p.is_file():
            extras[key] = str(p)
    return extras


def resolve(spec: dict, args) -> AcquireResult:
    opts = (spec.get("acquire") or {})
    directory = Path(opts.get("manual_dir", str(SOURCE_DIR)))
    prefix = opts.get("manual_prefix", "gb_tariff")

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
    spec_manual["acquire"] = {"options": {"dir": str(directory),
                                          "prefix": prefix}}
    res = _manual.resolve(spec_manual, _A)
    state = load_state()
    if state.get("measures_version"):
        res.extras.update(_extras_for(state["measures_version"]))
    return res


def fetch(spec: dict, args) -> AcquireResult:
    session = _session()
    opts = (spec.get("acquire") or {}).get("options") or {}
    dest_template = opts.get(
        "dest", "data/gb_tariff_source/gb_tariff_{year}_rev_{number}.csv")

    upstream = getattr(args, "upstream_extras", None) or {}
    mode = upstream.get("mode", "full")
    version = upstream.get("version")
    published = upstream.get("published")
    if not version:
        version, published = resolve_latest_version(session)
    print(f"[acquire:uk_tariff] pinned version {version} "
          f"(published {published}, mode {mode})")
    assert_csvw_schema(session, version)
    vdir = CACHE_DIR / version

    commodities = download_commodities(session, version)
    measures = vdir / "measures_as_defined.csv"
    if not measures.is_file():
        print("[acquire:uk_tariff] downloading measures-as-defined (~32 MB)")
        _download(session,
                  f"{API}/versions/{version}/tables/measures-as-defined/data"
                  f"?format=csv&download", measures)
    dec_path = vdir / "declarable.json"
    if dec_path.is_file():
        declarable = json.loads(dec_path.read_text(encoding="utf-8"))
    else:
        print("[acquire:uk_tariff] streaming measures-on-declarable "
              "(~357 MB, not stored)")
        declarable = stream_declarable(session, version, dec_path)
    if not (vdir / "geo_areas.json").is_file():
        fetch_geo_areas(session, vdir / "geo_areas.json")

    state = load_state()
    dec_sids = set(declarable["declarable_sids"])
    if mode == "rates_only":
        # The corpus revision stands; only the measure artifacts move.
        rev_id = state.get("corpus_revision")
        if not rev_id:
            raise SystemExit("ERROR: rates_only refresh but state.json has no "
                             "corpus_revision — run a full rollout first")
        year, num = int(rev_id[:4]), int(rev_id.split("_rev_")[1])
        dest = Path(dest_template.format(year=year, number=num))
        if not dest.is_file():
            raise SystemExit(f"ERROR: rates_only refresh but the corpus CSV "
                             f"{dest} is missing — run a full rollout first")
        effective = state.get("corpus_effective", published)
    else:
        year = int(published[:4])
        num = version_patch(version)
        rev_id = f"{year}_rev_{num}"
        dest = Path(dest_template.format(year=year, number=num))
        convert(commodities, dec_sids, dest)
        state["corpus_version"] = version
        state["corpus_revision"] = rev_id
        state["corpus_effective"] = published
        state["classification_hash"] = classification_hash(commodities)
        effective = published

    state["measures_version"] = version
    state["measures_published"] = published
    save_state(state)

    d = _dt.date.fromisoformat(effective)
    return AcquireResult(
        rev_id=rev_id, year=year, rev_num=num,
        effective_date=effective,
        effective_date_label=f"{d.strftime('%B')} {d.day}, {d.year}",
        source_csv=str(dest),
        source_url=f"{API}/versions/{version}/metadata?format=html",
        source_sha256=_sha256(dest),
        acquired_at=_dt.datetime.now(_dt.timezone.utc).isoformat(),
        extras=_extras_for(version),
    )


def check_latest(spec: dict, args):
    """Two-stage nightly gate (see module docstring). Stage 2's commodities
    download lands in the version cache dir, so a proceeding fetch() reuses
    it instead of downloading twice."""
    from check_upstream import UpstreamCheck

    session = _session()
    version, published = resolve_latest_version(session)
    state = load_state()
    patch = version_patch(version)
    year = int(published[:4])

    if version == state.get("measures_version"):
        # Nothing new upstream at all: report the registered corpus revision
        # so the generic ==/skip comparison closes the loop.
        rev = state.get("corpus_revision", f"{year}_rev_{patch}")
        return UpstreamCheck(
            status="available", rev_id=rev,
            year=int(rev[:4]), rev_num=int(rev.split("_rev_")[1]),
            effective_date=state.get("corpus_effective", published),
            detail=f"dataset version {version} already ingested",
            extras={"mode": "full", "version": version,
                    "published": published})

    commodities = download_commodities(session, version)
    new_hash = classification_hash(commodities)
    if state.get("classification_hash") and \
            new_hash == state["classification_hash"]:
        # Nomenclature unchanged: measures-only churn. Not a new corpus
        # revision — refresh the duty artifacts under the standing one.
        return UpstreamCheck(
            status="available",
            rev_id=state.get("corpus_revision"),
            year=int(state["corpus_revision"][:4]),
            rev_num=int(state["corpus_revision"].split("_rev_")[1]),
            effective_date=published,
            detail=(f"version {version}: nomenclature unchanged — duty "
                    f"measures refresh only"),
            extras={"mode": "rates_only", "version": version,
                    "published": published})

    return UpstreamCheck(
        status="available", rev_id=f"{year}_rev_{patch}",
        year=year, rev_num=patch, effective_date=published,
        detail=f"dataset version {version} changes the nomenclature "
               f"(classification hash differs)",
        extras={"mode": "full", "version": version, "published": published})


def _cli(argv=None) -> int:
    import argparse
    p = argparse.ArgumentParser(description="UK tariff adapter utilities")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert")
    c.add_argument("--commodities", required=True, type=Path)
    c.add_argument("--declarable", required=True, type=Path,
                   help="declarable.json from a fetch (sid universe)")
    c.add_argument("--out", required=True, type=Path)
    h = sub.add_parser("hash")
    h.add_argument("--commodities", required=True, type=Path)
    args = p.parse_args(argv)
    if args.cmd == "convert":
        dec = json.loads(args.declarable.read_text(encoding="utf-8"))
        convert(args.commodities, set(dec["declarable_sids"]), args.out)
    elif args.cmd == "hash":
        print(classification_hash(args.commodities))
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
