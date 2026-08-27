#!/usr/bin/env python3
"""build_duty_rates.py — derived duty rates for CA / EU / DO.

Deliberately SEPARATE from the US tariff-rates module (Avalara / §232 / Ch.99
/ MotherDuck): for these jurisdictions the statutory rate is derivable from
the published schedule itself. Emits, per jurisdiction:

  <jur>_<revision>.rates/chNN.json   one file per chapter (compact records)
  <jur>_<revision>.rates.index.json  chapter -> file map + counts
  <jur>.treatments.json              treatment -> origins + a COVERAGE block
                                     (what this data provides / excludes —
                                     rendered verbatim by the UI so the
                                     frontend can never overclaim)

Sources (ship what each source actually contains — user decision 2026-08-27):

  cbsa   TPHS's 25 treatment columns, INHERITED leaf->root over the CORRECTED
         tree from build_hts_corpus (the inheritance idea is ported from
         legacy/build_canada_tphs_artifacts_v4.py inherited_rates(); its own
         tree had 4 documented defects, so the values ride our tree instead).
         Origin mapping: config/ca_tariff_treatments.json (emitted from the
         hand-reviewed YAML — the mapping is NOT in TPHS).
         HONEST GAPS (in coverage block): SIMA anti-dumping and the 2024-25
         surtax orders are separate CBSA publications, NOT in TPHS.

  taric  The CIRCABC monthly extract, five workbooks:
           Duties Import 01-99.xlsx        (REQUIRED)  all import measures
           Geographical areas composition  (REQUIRED)  origin group -> members
           Measure exclusions              (REQUIRED)  6,553 active exclusions
                                           on duty measures — without them a
                                           preference is claimed for origins
                                           the measure explicitly excludes
           Measure conditions              (optional)  interprets "Cond:" duties
           Additional codes descriptions   (optional)  AD/CVD exporter names
         Measures are declared at ancestor codes; records are INHERITED to
         every leaf of the nomenclature (57.8% of leaves have no exact-code
         MFN row without this). Measure 103 rows with a non-erga-omnes origin
         (RU/BY sanctions) are their own treatment, never MFN. End-dated rows
         are dropped only when the end date is BEFORE the snapshot date
         (19,844 rows carry future end dates and are in force).
         HONEST GAPS: quota open/closed status (daily system), no AVE
         synthesis for specific/Meursing duties, no member-state VAT.

  dga    Grav. (MFN) per 8-digit line; ITBIS / Selectivo carried as tax
         records. NO preferential data exists in the book — DR-CAFTA/EPA
         schedules are separate treaty annexes, deliberately absent.

Never an origin determination: the consumer lists every applicable treatment
and marks the lowest; entitlement (rules of origin, direct shipment) is the
importer's question.
"""
from __future__ import annotations

import argparse
import csv
import datetime as _dt
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_hts_corpus as bhc  # noqa: E402


def load_overlay(jur: str) -> dict:
    """Curated per-jurisdiction overlay (config/duty_overlays/<jur>.json):
    flat taxes, surtax alerts, treaty preferences, VAT reference tables.
    Applied automatically on EVERY build so new revisions inherit them; each
    entry carries its own honesty flags (verified / notes) which the UI
    renders verbatim."""
    path = Path(f"config/duty_overlays/{jur.lower()}.json")
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {k: v for k, v in data.items() if not k.startswith("_")}

CA_RATE_COLUMNS = [
    "MFN", "AUT", "NZT", "CCCT", "LDCT", "GPT", "UST", "MXT", "CIAT", "CT",
    "CRT", "IT", "NT", "SLT", "PT", "COLT", "JT", "PAT", "HNT", "KRT",
    "CEUT", "CPTPT", "UKT", "UAT", "General Tariff",
]

_PCT_RE = re.compile(r"^\s*(\d+(?:[.,]\d+)?)\s*%\s*$")
# Leading ad-valorem component of a compound duty: "10.200 % + 93.100 EUR DTN"
_LEADING_PCT_RE = re.compile(r"^\s*(\d+(?:[.,]\d+)?)\s*%\s*\+")


def classify_rate(text: str) -> dict:
    """rate_text -> {rate_kind, ad_valorem}.

    compound duties keep their leading percentage so the best-rate comparison
    can still see them (rate_kind='compound' tells the UI the % is partial);
    'Cond:' strings are conditional; pure specific amounts stay 'other'."""
    t = (text or "").strip()
    if not t:
        return {"rate_kind": "none", "ad_valorem": None}
    if t.lower().rstrip() in ("free", "0", "0%", "0.000 %", "0.000%"):
        return {"rate_kind": "free", "ad_valorem": 0.0}
    m = _PCT_RE.match(t)
    if m:
        return {"rate_kind": "ad_valorem",
                "ad_valorem": round(float(m.group(1).replace(",", ".")) / 100, 6)}
    if t.startswith("Cond:"):
        return {"rate_kind": "conditional", "ad_valorem": None}
    m = _LEADING_PCT_RE.match(t)
    if m:
        return {"rate_kind": "compound",
                "ad_valorem": round(float(m.group(1).replace(",", ".")) / 100, 6)}
    return {"rate_kind": "other", "ad_valorem": None}


def _record(jur, revision, code, digits, treatment, rate_text, source_code=None,
            informational=False, category="duty", conditional=False):
    """Compact on purpose: jurisdiction/revision live once in the chapter-file
    wrapper, and null/false fields are omitted — the EU per-leaf expansion is
    hundreds of thousands of records and the UI fetches one chapter at a time."""
    rec = {"code": code, "digits": digits, "treatment": treatment,
           "rate_text": (rate_text or "").strip()}
    cls = classify_rate(rate_text)
    rec["rate_kind"] = cls["rate_kind"]
    if cls["ad_valorem"] is not None:
        rec["ad_valorem"] = cls["ad_valorem"]
    if source_code:
        rec["source_code"] = source_code
    if category != "duty":
        rec["category"] = category
    if informational:
        rec["informational"] = True
    if conditional:
        rec["conditional"] = True
    return rec


# ── Canada ───────────────────────────────────────────────────────────────────

CA_COVERAGE = {
    "provides": [
        "Statutory schedule rates at 10-digit depth: MFN plus every "
        "preferential tariff treatment printed in the Customs Tariff "
        "schedule (24 treatment columns), with rates inherited from parent "
        "tariff items exactly as the printed book implies.",
        "General Tariff (35%) fallback for origins with no other entitlement.",
    ],
    "excludes": [
        "SIMA anti-dumping/countervailing duties (CBSA 'Measures in Force' "
        "is a separate publication, not part of the tariff schedule).",
        "Provincial HST/PST and excise taxes (federal GST is shown; the "
        "provincial component depends on the province of delivery).",
        "Exact surtax-order scope: China surtax orders surface as ALERTS on "
        "matching chapters/subheadings until their tariff-item lists are "
        "transcribed and marked verified — an alert is a flag to check the "
        "Order, not an asserted rate.",
        "Tariff-rate-quota within-access permit logic (over-access rates are "
        "the schedule rates shown).",
        "Ad-valorem equivalents for specific/compound rates (shown verbatim, "
        "excluded from lowest-rate comparison).",
    ],
    "source": "CBSA Customs Tariff (TPHS table, Access distribution)",
}


def build_ca(csv_path: Path, jur: str, revision: str):
    rows, stats = bhc.load_rows_cbsa(csv_path)
    roots = bhc.build_tree(rows)

    raw_rates: dict[str, dict[str, str]] = {}
    with csv_path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            digits = bhc._digits_only(r.get("TARIFF") or "")
            if digits and digits not in raw_rates:
                raw_rates[digits] = r
    first = next(iter(raw_rates.values()))
    cols = [c for c in CA_RATE_COLUMNS if c in first]

    records = []

    def walk(node, path):
        code = (node.get("HTS Number") or "").strip()
        digits = bhc._digits_only(code)
        if not node["children"] and digits:
            # inheritance ported from legacy inherited_rates(): walk leaf->root
            # taking the first non-empty value per column, recording the
            # ancestor it came from — but over the CORRECTED tree.
            chain = [node] + list(reversed(path))
            for col in cols:
                for anc in chain:
                    anc_digits = bhc._digits_only(anc.get("HTS Number") or "")
                    val = (raw_rates.get(anc_digits, {}).get(col) or "").strip()
                    if val:
                        records.append(_record(
                            jur, revision, code, digits, col, val,
                            source_code=(anc.get("HTS Number") or "").strip()
                            if anc is not node else None))
                        break
        for child in node["children"]:
            walk(child, path + [node])

    for root in roots:
        walk(root, [])

    overlay = load_overlay("ca")
    # Surtax alerts: informational warning rows on matching leaves — a flag to
    # check the Order in Council, never an asserted rate while verified:false.
    for alert in overlay.get("surtax_alerts", []):
        prefixes = tuple(alert.get("prefixes", []))
        matched = 0
        for rec in list(records):
            if rec["treatment"] != "MFN":
                continue                       # one alert per leaf, keyed off MFN rows
            if not rec["digits"].startswith(prefixes):
                continue
            out = _record(jur, revision, rec["code"], rec["digits"],
                          f"surtax_alert_{alert['id']}", alert["rate_text"],
                          informational=True, category="alert",
                          conditional=True)
            out["origin_code"] = ",".join(alert.get("origin_countries", []))
            out["origin_name"] = alert["name"]
            records.append(out)
            matched += 1
        print(f"[ca] surtax alert {alert['id']}: {matched:,} leaves flagged")

    treatments_path = Path("config/ca_tariff_treatments.json")
    treatments = json.loads(treatments_path.read_text(encoding="utf-8"))["treatments"]
    tout = []
    for code_key, t in treatments.items():
        origins = t.get("origin_countries") or []
        if isinstance(origins, str):
            origins = [origins]
        tout.append({
            "treatment": code_key, "name": t["name"],
            "origin_countries": origins,
            "applies": t.get("applies"),
            "conditional": bool(t.get("conditional")),
            "legal_basis": t.get("legal_basis", ""),
            "transcription_pending": bool(t.get("transcription_pending")),
        })
    for alert in overlay.get("surtax_alerts", []):
        tout.append({
            "treatment": f"surtax_alert_{alert['id']}",
            "name": alert["name"],
            "origin_countries": alert.get("origin_countries", []),
            "applies": None, "conditional": True,
            "legal_basis": alert.get("legal_basis", ""),
            "transcription_pending": not alert.get("verified", False),
            "category": "alert",
            "scope_note": alert.get("scope_note", ""),
        })
    coverage = dict(CA_COVERAGE)
    coverage["flat_taxes"] = overlay.get("flat_taxes", [])
    coverage["provides"] = coverage["provides"] + [
        "Federal GST (5%) as a flat import-tax line, and China surtax-order "
        "ALERTS on matching goods (scope pending verification against the "
        "Orders' tariff-item lists).",
    ]
    return records, tout, coverage


# ── EU ───────────────────────────────────────────────────────────────────────

# Duty measures (expanded to every leaf; drive the applicable-rate answer).
EU_MEASURE_DUTY = {
    "103": "third_country",     # erga omnes MFN — or an origin-specific
                                # sanctions duty when Origin code != 1011
    "106": "customs_union",
    "141": "preference",        # preferential under end-use/quota-free
    "142": "preference",
    "112": "suspension",        # replaces the 103 duty when conditions met
}
# Informational measures (kept at their declared codes; the API prefix-matches
# these so an ancestor-declared AD/CVD still surfaces on its leaves).
EU_MEASURE_INFO = {"552": "anti_dumping", "554": "countervailing",
                   "122": "quota_non_pref", "143": "quota_pref",
                   "117": "suspension_ships", "695": "additional_duties"}

ERGA_OMNES_CODE = "1011"

# The 12-column Duties Import header. Whitespace-normalized before comparing —
# the sibling TARIC measures.xlsx carries leading spaces on two headers.
EXPECTED_DUTIES_COLUMNS = (
    "Goods code", "Add code", "Order No.", "Start date", "End date",
    "RED_IND", "Origin", "Measure type", "Legal base", "Duty",
    "Origin code", "Meas. type code",
)

EU_COVERAGE = {
    "provides": [
        "Full statutory per-origin picture at 10-digit TARIC depth: MFN "
        "(erga omnes third-country duty), customs-union rates, tariff "
        "preferences for every origin/agreement in TARIC (with measure "
        "exclusions applied), autonomous suspensions (conditional), and "
        "anti-dumping/countervailing duties per exporter additional code.",
        "Rates inherited from the code level where TARIC declares them down "
        "to every declarable 10-digit line.",
    ],
    "excludes": [
        "Tariff-quota open/closed status and balances (a daily system; "
        "in/out-of-quota rates are listed as informational, never asserted "
        "as the applicable rate).",
        "Ad-valorem equivalents for specific, compound or Meursing (EA/ADSZ) "
        "duties — the formula is shown verbatim; only a compound duty's "
        "leading percentage enters the rate comparison.",
        "Excise duties, and product-specific reduced/zero VAT rates — the "
        "standard import-VAT reference table by destination member state IS "
        "included, but it is a reference, not a per-product determination.",
        "Measures published after this monthly snapshot (each measure also "
        "carries its own legal dates).",
    ],
    "source": "EU TARIC monthly extract (CIRCABC)",
}


def _parse_ddmmyyyy(s: str) -> _dt.date | None:
    s = (s or "").strip()
    if not s:
        return None
    if s.isdigit():
        raise SystemExit(
            f"ERROR: date cell {s!r} looks like an Excel serial number — this "
            f"workbook is in the TARIC-measures encoding, not the Duties "
            f"Import encoding. Refusing to guess an epoch.")
    try:
        return _dt.datetime.strptime(s, "%d-%m-%Y").date()
    except ValueError:
        raise SystemExit(f"ERROR: unparseable date {s!r} (expected dd-mm-yyyy)")


def _assert_duties_header(rows: list[dict]) -> None:
    header = tuple(" ".join((rows[0].get(chr(ord("A") + i)) or "").split())
                   for i in range(12))
    expected = tuple(" ".join(c.split()) for c in EXPECTED_DUTIES_COLUMNS)
    if header != expected:
        raise SystemExit(
            "ERROR: Duties Import header changed upstream.\n"
            f"  expected: {expected}\n  got:      {header}\n"
            "A schema change must be reviewed, not silently ingested.")


def _load_eu_leaf_tree(nomenclature_csv: Path):
    """(leaves, declared_ancestor_chain) from the canonical EU CSV.

    A TARIC code's ancestors are its even-length prefixes zero-padded back to
    10 digits (the padding means a CN8-terminal leaf and its CN8 ancestor are
    the SAME string, which is exactly why self-lookup comes first)."""
    leaves: list[str] = []
    with nomenclature_csv.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            if (r.get("SUFFIX") or "") == "80" and (r.get("IS_LEAF") or "") == "1":
                leaves.append((r.get("GOODS_CODE") or "").strip())
    if not leaves:
        raise SystemExit(f"ERROR: no IS_LEAF rows in {nomenclature_csv}")
    return leaves


def _eu_ancestors(digits: str) -> list[str]:
    """Self first, then progressively shorter even prefixes padded to 10."""
    out = [digits]
    for length in (8, 6, 4, 2):
        cand = digits[:length] + "0" * (10 - length)
        if cand != out[-1]:
            out.append(cand)
    return out


def _display(digits: str) -> str:
    return f"{digits[:4]}.{digits[4:6]}.{digits[6:8]}.{digits[8:10]}"


def build_eu(duties_xlsx: Path, geo_xlsx: Path | None, jur: str, revision: str,
             nomenclature_csv: Path, snapshot_date: _dt.date,
             exclusions_xlsx: Path | None = None,
             conditions_xlsx: Path | None = None,
             addcodes_xlsx: Path | None = None):
    from acquire._xlsx_lite import read_sheets

    # ── origin groups ────────────────────────────────────────────────
    groups: dict[str, list[str]] = {}
    if geo_xlsx and geo_xlsx.exists():
        for rows in read_sheets(str(geo_xlsx)).values():
            for r in rows[1:]:
                grp = (r.get("A") or "").strip()
                member = (r.get("F") or "").strip()
                end = (r.get("J") or "").strip() or (r.get("K") or "").strip()
                if grp and member and not end:
                    groups.setdefault(grp, []).append(member)
    else:
        raise SystemExit("ERROR: Geographical areas composition workbook is "
                         "required — origin groups cannot be expanded without it")

    # Nested-bloc expansion: several TARIC groups (EU-Canada / EU-Switzerland
    # re-imported-goods arrangements, PAN-EU cumulation) list the synthetic
    # member "EU" rather than the member states. Expand it to group 1010's
    # real members so (a) the UI never shows "EU" as if it were a country and
    # (b) an origin like DE correctly matches those arrangements.
    eu_members = [m for m in groups.get("1010", []) if m != "EU"]
    for grp, members in groups.items():
        if "EU" in members and eu_members:
            groups[grp] = sorted(set(m for m in members if m != "EU") | set(eu_members))

    # ── measure exclusions ───────────────────────────────────────────
    # key: (digits, measure_type, origin_code, add_code) -> {excluded ISO}
    # An exclusion row without an add code applies to every add code of the
    # measure, so lookups merge the add-code-specific and blank-add-code sets.
    exclusions: dict[tuple, set] = {}
    if exclusions_xlsx and exclusions_xlsx.exists():
        for rows in read_sheets(str(exclusions_xlsx)).values():
            for r in rows[1:]:
                code = (r.get("A") or "").strip()
                if not (code.isdigit() and len(code) == 10):
                    continue
                end = _parse_ddmmyyyy(r.get("E") or "")
                if end and end < snapshot_date:
                    continue
                key = (code, (r.get("J") or "").strip(),
                       (r.get("I") or "").strip(), (r.get("B") or "").strip())
                exclusions.setdefault(key, set()).add((r.get("K") or "").strip())
    else:
        raise SystemExit("ERROR: Measure exclusions workbook is required — "
                         "6,553 active exclusions change which origins a duty "
                         "measure applies to; omitting them overstates "
                         "preference coverage")

    def excluded_for(code, mtype, origin_code, add_code) -> list[str]:
        out = set()
        out |= exclusions.get((code, mtype, origin_code, add_code), set())
        if add_code:
            out |= exclusions.get((code, mtype, origin_code, ""), set())
        return sorted(o for o in out if o)

    # ── measure conditions (optional): compact certificate summary ───
    conditions: dict[tuple, list[str]] = {}
    if conditions_xlsx and conditions_xlsx.exists():
        for rows in read_sheets(str(conditions_xlsx)).values():
            for r in rows[1:]:
                code = (r.get("A") or "").strip()
                if not (code.isdigit() and len(code) == 10):
                    continue
                if (r.get("E") or "").strip():
                    end = _parse_ddmmyyyy(r.get("E") or "")
                    if end and end < snapshot_date:
                        continue
                cert = (r.get("J") or "").strip()
                amount = (r.get("K") or "").strip()
                unit = (r.get("L") or "").strip() or (r.get("M") or "").strip()
                part = cert or (f"{amount} {unit}".strip() if amount else "")
                if not part:
                    continue
                key = (code, (r.get("G") or "").strip(),
                       (r.get("F") or "").strip(), (r.get("B") or "").strip())
                bucket = conditions.setdefault(key, [])
                if part not in bucket:
                    bucket.append(part)

    # ── additional-code names (optional, EN) ─────────────────────────
    addcode_names: dict[str, str] = {}
    if addcodes_xlsx and addcodes_xlsx.exists():
        for rows in read_sheets(str(addcodes_xlsx)).values():
            for r in rows[1:]:
                if (r.get("B") or "").strip() != "EN":
                    continue
                if (r.get("F") or "").strip():
                    continue
                ac = (r.get("A") or "").strip()
                if ac and ac not in addcode_names:
                    addcode_names[ac] = " ".join((r.get("C") or "").split())[:80]

    # ── duties workbook ──────────────────────────────────────────────
    # declared duty measures: key -> (rate_text, add_code, origin fields...)
    declared_duty: dict[str, dict[tuple, dict]] = {}   # digits -> key -> rec
    info_records: list[dict] = []
    seen_info: set = set()

    sheets = read_sheets(str(duties_xlsx))
    for rows in sheets.values():
        if not rows:
            continue
        _assert_duties_header(rows)
        for r in rows[1:]:
            code = (r.get("A") or "").strip()
            if not (code.isdigit() and len(code) == 10):
                continue
            end = _parse_ddmmyyyy(r.get("E") or "")
            if end and end < snapshot_date:
                continue                                    # genuinely expired
            mtype = " ".join((r.get("L") or "").split())
            duty = (r.get("J") or "").strip()
            add_code = (r.get("B") or "").strip()
            origin_code = (r.get("K") or "").strip()
            origin_name = (r.get("G") or "").strip()
            valid_until = (r.get("E") or "").strip()

            if mtype in EU_MEASURE_DUTY:
                kind = EU_MEASURE_DUTY[mtype]
                if kind == "third_country":
                    treatment = ("erga_omnes" if origin_code == ERGA_OMNES_CODE
                                 else f"third_country_{origin_code}")
                elif kind == "customs_union":
                    treatment = f"customs_union_{origin_code}"
                elif kind == "suspension":
                    treatment = (f"suspension_{origin_code}"
                                 if origin_code != ERGA_OMNES_CODE
                                 else "suspension")
                else:
                    treatment = f"pref_{origin_code}"
                key = (treatment, origin_code, add_code)
                rec = {"treatment": treatment, "rate_text": duty,
                       "add_code": add_code, "origin_code": origin_code,
                       "origin_name": origin_name, "measure_type": mtype,
                       "valid_until": valid_until,
                       "excluded_origins": excluded_for(code, mtype,
                                                        origin_code, add_code),
                       "conditions": conditions.get(
                           (code, mtype, origin_code, add_code), [])}
                declared_duty.setdefault(code, {})[key] = rec
            elif mtype in EU_MEASURE_INFO:
                dedupe = (code, mtype, origin_code, add_code, duty)
                if dedupe in seen_info:
                    continue                       # 14k byte-identical dupes
                seen_info.add(dedupe)
                rec = _record(jur, revision, _display(code), code,
                              EU_MEASURE_INFO[mtype], duty,
                              informational=True, category="measure")
                rec["origin_code"] = origin_code
                rec["origin_name"] = origin_name
                rec["measure_type"] = mtype
                if add_code:
                    rec["add_code"] = add_code
                    if add_code in addcode_names:
                        rec["add_code_name"] = addcode_names[add_code]
                if valid_until:
                    rec["valid_until"] = valid_until
                info_records.append(rec)

    if not declared_duty:
        raise SystemExit("ERROR: no duty measures parsed from the Duties "
                         "Import workbook")

    # ── emit DECLARED-level records; inheritance happens at query time ──
    # Materializing every (leaf × treatment × origin) row was measured at
    # 220 MB per revision. Instead the records stay at the code where TARIC
    # declares them (~100k rows, ~35 MB) and the consumer resolves a leaf by
    # walking its ancestor chain (self, CN8, HS6, HS4, chapter — all in the
    # SAME chapter file) taking the most specific declaration per
    # (treatment, origin, add_code). dutyRates.ts implements that walk; the
    # `inherit: "ancestor-walk"` flag in the index tells it to.
    records: list[dict] = []
    for code in sorted(declared_duty):
        for (treatment, origin_code, add_code), rec in declared_duty[code].items():
            kind = EU_MEASURE_DUTY.get(rec["measure_type"], "")
            out = _record(
                jur, revision, _display(code), code, treatment,
                rec["rate_text"],
                conditional=(kind == "suspension"
                             or rec["rate_text"].startswith("Cond:")
                             or (kind == "third_country"
                                 and origin_code != ERGA_OMNES_CODE)))
            out["origin_code"] = origin_code
            if rec["origin_name"]:
                out["origin_name"] = rec["origin_name"]
            out["measure_type"] = rec["measure_type"]
            if add_code:
                out["add_code"] = add_code
                if add_code in addcode_names:
                    out["add_code_name"] = addcode_names[add_code]
            if rec["valid_until"]:
                out["valid_until"] = rec["valid_until"]
            if rec["excluded_origins"]:
                out["excluded_origins"] = rec["excluded_origins"]
            if rec["conditions"]:
                out["conditions"] = rec["conditions"]
            records.append(out)

    # ── coverage VERIFICATION (nothing emitted): every leaf must reach an
    # erga-omnes rate through its ancestor chain ─────────────────────────
    leaves = _load_eu_leaf_tree(nomenclature_csv)
    covered_mfn = 0
    for leaf in leaves:
        for anc in _eu_ancestors(leaf):
            if any(k[0] == "erga_omnes" for k in declared_duty.get(anc, {})):
                covered_mfn += 1
                break
    pct = 100.0 * covered_mfn / len(leaves)
    print(f"[eu] MFN (erga omnes) coverage via ancestor walk: "
          f"{covered_mfn:,}/{len(leaves):,} leaves ({pct:.1f}%)")
    if pct < 90.0:
        raise SystemExit(f"ERROR: EU MFN leaf coverage {pct:.1f}% is below the "
                         f"90% sanity floor — inheritance or parsing regressed "
                         f"(audited floor is ~95.7%)")

    records.extend(info_records)

    # ── treatments file ──────────────────────────────────────────────
    origin_treatments: dict[str, dict] = {}
    for recs in declared_duty.values():
        for (treatment, origin_code, _ac), rec in recs.items():
            if treatment in ("erga_omnes",) or treatment in origin_treatments:
                continue
            members = groups.get(origin_code,
                                 [origin_code] if len(origin_code) == 2 else [])
            kind = EU_MEASURE_DUTY.get(rec["measure_type"], "")
            origin_treatments[treatment] = {
                "treatment": treatment,
                "name": (f"Tariff preference — {rec['origin_name']}"
                         if kind == "preference" else
                         f"{kind.replace('_', ' ').title()} — {rec['origin_name']}"),
                "origin_countries": sorted(set(members)),
                "applies": None,
                "conditional": True,    # preferences require origin entitlement
                "legal_basis": f"TARIC measure {rec['measure_type']}",
            }
    tout = [{"treatment": "erga_omnes",
             "name": "Third country duty (erga omnes MFN)",
             "origin_countries": [], "applies": "all_origins",
             "conditional": False,
             "legal_basis": "Reg. (EEC) 2658/87 Annex I / TARIC measure 103"}]
    tout += [origin_treatments[k] for k in sorted(origin_treatments)]
    coverage = dict(EU_COVERAGE)
    coverage["as_of"] = snapshot_date.isoformat()
    # WHERE these rates apply: TARIC geographical group 1010 ("European
    # Union") is the authoritative member list from the same extract — the 27
    # member states plus XI (Northern Ireland, under the EU goods regime per
    # the Windsor Framework). The synthetic "EU" member code is dropped.
    overlay = load_overlay("eu")
    if overlay.get("member_import_vat"):
        coverage["member_import_vat"] = overlay["member_import_vat"]
    members = sorted(m for m in groups.get("1010", []) if m != "EU")
    if members:
        coverage["applies_in"] = members
        coverage["applies_in_note"] = (
            "These rates apply to imports into the customs territory of the "
            "European Union — all member states"
            + (" and Northern Ireland (XI, under the Windsor Framework goods "
               "regime)" if "XI" in members else "") + ".")
    return records, tout, coverage


# ── Dominican Republic ───────────────────────────────────────────────────────

DO_COVERAGE = {
    "provides": [
        "Statutory MFN duty (Gravamen, ad valorem) at 8-digit depth for the "
        "complete Arancel de Aduanas (7ma Enmienda).",
        "Import taxes as separate components: ITBIS (VAT) and Impuesto "
        "Selectivo al Consumo (ad valorem and specific).",
    ],
    "excludes": [
        "EU EPA (EPA CARIFORUM-UE) and CARICOM preferential schedules — "
        "separate treaty annexes not yet transcribed (DR-CAFTA IS included, "
        "from the curated overlay).",
        "Anti-dumping/safeguard measures.",
        "Exact landed-cost computation: the total shown is the sum of the "
        "listed ad-valorem line items; DGA liquidation applies ISC/ITBIS on "
        "cascading bases, and specific ISC amounts (DOP per unit) are shown "
        "verbatim, never converted to a percentage.",
    ],
    "source": "DGA Arancel de Aduanas, 7ma Enmienda (2022)",
}


def build_do(csv_path: Path, jur: str, revision: str):
    records = []
    with csv_path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            clean = {(k or "").strip(): (v or "").strip() for k, v in r.items()}
            code = clean.get("Código", "")
            if "[" in code:
                continue
            digits = bhc._digits_only(code)
            if len(digits) != 8:
                continue
            grav = clean.get("Grav.", "")
            if grav:
                records.append(_record(jur, revision, code, digits, "MFN",
                                       f"{grav}%"))
            itbis = clean.get("ITBIS*", "") or clean.get("ITBIS", "")
            if itbis:
                records.append(_record(jur, revision, code, digits, "ITBIS",
                                       f"{itbis}%", informational=True,
                                       category="tax"))
            sav = clean.get("Selectivo Ad Valorem", "")
            if sav:
                records.append(_record(jur, revision, code, digits,
                                       "ISC_AD_VALOREM", f"{sav}%",
                                       informational=True, category="tax"))
            se = clean.get("Selectivo Específico", "")
            if se:
                records.append(_record(jur, revision, code, digits,
                                       "ISC_ESPECIFICO", se,
                                       informational=True, category="tax"))
    # Full nomenclature, Spanish first with English translation — these names
    # render verbatim as the line items in the UI.
    overlay = load_overlay("do")
    pref_records = []
    for pref in overlay.get("preferences", []):
        exceptions = tuple(pref.get("exception_prefixes", []))
        added = 0
        for rec in list(records):
            if rec["treatment"] != "MFN":
                continue
            if exceptions and rec["digits"].startswith(exceptions):
                continue
            out = _record(jur, revision, rec["code"], rec["digits"],
                          pref["treatment"], pref["rate_text"],
                          conditional=bool(pref.get("conditional", True)))
            out["origin_code"] = ",".join(pref.get("origin_countries", []))
            pref_records.append(out)
            added += 1
        print(f"[do] preference {pref['treatment']}: {added:,} leaves covered")
    records.extend(pref_records)

    tout = [
        {"treatment": "MFN",
         "name": "Gravamen — Customs duty (tariff)",
         "origin_countries": [], "applies": "all_origins", "conditional": False,
         "legal_basis": "Arancel de Aduanas RD, 7ma Enmienda"},
        {"treatment": "ISC_AD_VALOREM",
         "name": "Impuesto Selectivo al Consumo, ad valorem — "
                 "Selective Consumption Tax (ad valorem)",
         "origin_countries": [], "applies": "all_origins", "conditional": False,
         "legal_basis": "Ley 11-92 Título IV", "category": "tax"},
        {"treatment": "ISC_ESPECIFICO",
         "name": "Impuesto Selectivo al Consumo, específico — "
                 "Selective Consumption Tax (specific, DOP per unit)",
         "origin_countries": [], "applies": "all_origins", "conditional": False,
         "legal_basis": "Ley 11-92 Título IV", "category": "tax"},
        {"treatment": "ITBIS",
         "name": "ITBIS, Impuesto sobre Transferencias de Bienes "
                 "Industrializados y Servicios — Tax on the Transfer of "
                 "Industrialized Goods and Services (VAT on import)",
         "origin_countries": [], "applies": "all_origins", "conditional": False,
         "legal_basis": "Ley 253-12", "category": "tax"},
    ]
    for pref in overlay.get("preferences", []):
        tout.append({
            "treatment": pref["treatment"], "name": pref["name"],
            "origin_countries": pref.get("origin_countries", []),
            "applies": None,
            "conditional": bool(pref.get("conditional", True)),
            "legal_basis": pref.get("legal_basis", ""),
            "note": pref.get("note", ""),
        })
    coverage = dict(DO_COVERAGE)
    if overlay.get("preferences"):
        coverage["provides"] = coverage["provides"] + [
            "DR-CAFTA duty-free treatment for originating goods of the "
            "parties (US, CR, GT, HN, NI, SV) — certification of origin "
            "required; from the curated overlay, re-applied on every build.",
        ]
    return records, tout, coverage


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("source", type=Path,
                   help="canonical CSV (cbsa/dga) or Duties Import xlsx (taric)")
    p.add_argument("--source-format", choices=("cbsa", "taric", "dga"), required=True)
    p.add_argument("--jurisdiction", required=True)
    p.add_argument("--revision", required=True)
    p.add_argument("--nomenclature", type=Path,
                   help="taric: the canonical EU nomenclature CSV (leaf set + "
                        "inheritance tree)")
    p.add_argument("--geo-areas", type=Path,
                   help="taric: Geographical areas composition.xlsx (REQUIRED)")
    p.add_argument("--exclusions", type=Path,
                   help="taric: Measure exclusions.xlsx (REQUIRED)")
    p.add_argument("--conditions", type=Path,
                   help="taric: Measure conditions.xlsx (optional)")
    p.add_argument("--addcodes", type=Path,
                   help="taric: Additional codes descriptions.xlsx (optional)")
    p.add_argument("--snapshot-date", default=None,
                   help="taric: the extract's snapshot date (YYYY-MM-DD); "
                        "measures whose end date is before this are dropped")
    p.add_argument("--out-dir", type=Path, default=Path("."))
    args = p.parse_args()

    jur = args.jurisdiction.upper()
    if args.source_format == "cbsa":
        records, treatments, coverage = build_ca(args.source, jur, args.revision)
    elif args.source_format == "taric":
        if not args.nomenclature:
            sys.exit("ERROR: --nomenclature is required for taric")
        if not args.snapshot_date:
            sys.exit("ERROR: --snapshot-date is required for taric")
        snapshot = _dt.date.fromisoformat(args.snapshot_date)
        records, treatments, coverage = build_eu(
            args.source, args.geo_areas, jur, args.revision,
            nomenclature_csv=args.nomenclature, snapshot_date=snapshot,
            exclusions_xlsx=args.exclusions, conditions_xlsx=args.conditions,
            addcodes_xlsx=args.addcodes)
    else:
        records, treatments, coverage = build_do(args.source, jur, args.revision)

    if not records:
        print("ERROR: no rate records produced", file=sys.stderr)
        return 2

    # collision check: a duplicate (code, treatment, origin, add_code) means
    # two indistinguishable rows would reach the UI
    seen_keys = set()
    dupes = 0
    for r in records:
        if r.get("informational"):
            continue
        k = (r["digits"], r["treatment"], r.get("origin_code", ""),
             r.get("add_code", ""))
        if k in seen_keys:
            dupes += 1
        seen_keys.add(k)
    if dupes:
        print(f"ERROR: {dupes:,} duplicate duty records on "
              f"(code, treatment, origin, add_code)", file=sys.stderr)
        return 3

    args.out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"{jur.lower()}_{args.revision}"

    by_chapter: dict[str, list] = {}
    for r in records:
        by_chapter.setdefault(r["digits"][:2], []).append(r)
    rates_dir = args.out_dir / f"{stem}.rates"
    rates_dir.mkdir(exist_ok=True)
    chapters_index = {}
    for ch in sorted(by_chapter):
        ch_path = rates_dir / f"ch{ch}.json"
        ch_path.write_text(json.dumps({
            "jurisdiction": jur, "revision": args.revision, "chapter": ch,
            "records": by_chapter[ch],
        }, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
        chapters_index[ch] = f"{stem}.rates/ch{ch}.json"

    index_path = args.out_dir / f"{stem}.rates.index.json"
    by_cat: dict[str, int] = {}
    for r in records:
        cat = r.get("category", "duty")
        by_cat[cat] = by_cat.get(cat, 0) + 1
    index_path.write_text(json.dumps({
        "jurisdiction": jur, "revision": args.revision,
        "record_count": len(records), "by_category": by_cat,
        # taric: records live at the code where TARIC declares the measure;
        # the consumer resolves a leaf by walking self -> CN8 -> HS6 -> HS4 ->
        # chapter (zero-padded), most specific per (treatment,origin,add_code).
        "inherit": ("ancestor-walk" if args.source_format == "taric" else "exact"),
        "chapters": chapters_index,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    treatments_path = args.out_dir / f"{jur.lower()}.treatments.json"
    treatments_path.write_text(
        json.dumps({"jurisdiction": jur, "treatments": treatments,
                    "coverage": coverage},
                   ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(records):,} rate records ({by_cat}) across "
          f"{len(by_chapter)} chapter files -> {rates_dir}/ + {index_path.name}")
    print(f"Wrote {len(treatments)} treatments + coverage -> {treatments_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
