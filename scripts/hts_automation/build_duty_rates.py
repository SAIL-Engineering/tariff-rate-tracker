#!/usr/bin/env python3
"""build_duty_rates.py — derived duty rates for CA / EU / DO (and GB, CH, KR,
TW, SG, MY, VN).

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

  sg / my / vn   Hand-acquired static editions, one canonical CSV each, like
         dga. SG: STCCED 2022 Full (blank = nil, see build_sg) / Pref /
         excise. MY: Customs Duties Order 2025 import duty, Appendix B quota
         rates, ezHS SST/excise/cess. VN: MFN + ordinary rate + VAT, each MFN
         rate citing its Decree. Specific/compound duties keep amount,
         currency and unit; cells that are not a representable rate are
         carried verbatim and flagged (category 'unknown', needs_review).

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
    "CEUT", "CPTPT", "UKT", "CPUKT", "UAT", "General Tariff",
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


XI_COVERAGE = {
    "provides": [
        "The EU-aligned duty baseline Northern Ireland applies under the "
        "Windsor Framework: TARIC third-country (erga omnes) rates, every "
        "EU tariff preference with member expansion and exclusions, "
        "customs-union rates, suspensions, and informational trade-remedy/"
        "quota measures — the rates payable for goods 'at risk' of moving "
        "into the EU.",
        "Monthly TARIC snapshot depth at the full 10-digit level.",
    ],
    "excludes": [
        "The 'not at risk' lane: goods brought into Northern Ireland under "
        "the UK Internal Market Scheme (UKIMS) that will stay in the UK pay "
        "the UK (GB) rate — usually lower, often zero. Check the United "
        "Kingdom schedule for that rate; at-risk determination is the "
        "trader's responsibility.",
        "Preferential origin-rule verification (preference rows are "
        "candidates, not entitlements).",
        "Tariff-quota balances/exhaustion status (in-quota rates are shown "
        "as conditional, never auto-selected).",
        "UK/EU VAT and excise on import.",
        "Duty reimbursement/waiver schemes for at-risk goods later shown to "
        "have remained in the UK.",
    ],
    "source": "Northern Ireland Online Tariff (EU TARIC baseline under the "
              "Windsor Framework; monthly CIRCABC extract)",
}


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
    coverage = dict(XI_COVERAGE if jur == "XI" else EU_COVERAGE)
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


# ── United Kingdom ───────────────────────────────────────────────────────────

# Duty-bearing measure types (become treatment rows the best-rate logic sees).
GB_MEASURE_DUTY = {
    "103": "third_country",     # UK Global Tariff MFN when area is 1011
    "105": "end_use",           # non-preferential duty under authorised use
    "112": "suspension_autonomous",
    "115": "suspension_end_use",
    "117": "suspension_ships",
    "119": "suspension_airworthiness",
    "142": "preference",
    "145": "preference_end_use",
}
# Informational categories (surface as rows, never MFN/best).
GB_MEASURE_INFO = {
    "122": "quota", "123": "quota", "143": "quota", "146": "quota",
    "551": "anti_dumping", "552": "anti_dumping",
    "553": "countervailing", "554": "countervailing",
    "555": "anti_dumping", "564": "trade_remedy_registration",
    "695": "additional_duties",
    "109": "supplementary_unit", "110": "supplementary_unit",
    "488": "unit_price",
}
GB_ERGA_OMNES = "1011"

GB_COVERAGE = {
    "provides": [
        "The complete UK tariff measure set at declared depth with ancestor "
        "inheritance: UK Global Tariff (third-country duty), every tariff "
        "preference with its origin list, authorised-use rates, and tariff "
        "suspensions — duty expressions verbatim from the official dataset.",
        "Trade remedies (anti-dumping/countervailing), tariff quotas, "
        "additional duties, and import/export controls listed as "
        "informational rows with legal citations (never summed into a rate).",
        "Refreshed from every new dataset version (published near-daily); "
        "the as-of line shows the exact version served.",
    ],
    "excludes": [
        "Preferential origin-rule verification: a preference row is a "
        "candidate, not an entitlement — proof of origin is required.",
        "Live tariff-quota balances/exhaustion status (quota rates are shown "
        "as conditional; the in-quota rate is never auto-selected).",
        "Import VAT beyond the standard-rate line shown (reduced and "
        "zero-rated goods exist; VAT/excise measures are not part of this "
        "dataset export), and excise duties.",
        "Measures requiring an additional code or certificate are shown as "
        "conditional, not asserted.",
        "Ad-valorem equivalents for specific/compound duties (shown "
        "verbatim, never converted).",
        "Northern Ireland import specifics: XI is legally part of the UK "
        "customs territory and NI-to-GB movements are unfettered, but goods "
        "ENTERING Northern Ireland operate the Windsor Framework "
        "dual-system — 'at risk' goods pay the EU-aligned Northern Ireland "
        "Online Tariff rate (see the Northern Ireland schedule); 'not at "
        "risk' UKIMS goods pay these UK rates.",
    ],
    "source": "UK Integrated Online Tariff (DBT Data API, "
              "uk-tariff-2021-01-01)",
}


def _gb_split(value: str) -> list[str]:
    v = (value or "").strip()
    if not v or v == "#NA":
        return []
    return [x.strip() for x in v.split("|") if x.strip()]


def build_gb(measures_csv: Path, geo_json: Path, jur: str, revision: str,
             nomenclature_csv: Path, snapshot_date, declarable_json: Path):
    """UK: measures-as-defined (declared-level, 87k rows) + ancestor-walk,
    mirroring the EU declared-level design. Geographic membership comes from
    the trade-tariff service API snapshot (the flattened CSVs name areas but
    not members); exclusions/conditions/footnotes/quotas arrive inline per
    row. The build hard-fails unless every leaf reaches a 103 erga-omnes
    rate AND a sampled reconciliation against the dataset's own leaf
    expansion (measures-on-declarable) round-trips."""
    geo = json.loads(geo_json.read_text(encoding="utf-8"))["areas"]
    eu_members = [m for m in geo.get("1013", {}).get("members", [])
                  if m not in ("EU",)]

    def area_members(area_id: str) -> list[str]:
        if area_id in geo and geo[area_id]["members"]:
            out = set()
            for m in geo[area_id]["members"]:
                out.update(eu_members if m == "EU" else [m])
            return sorted(out)
        return [area_id] if len(area_id) == 2 else []

    def expand_exclusions(ids: list[str]) -> list[str]:
        out = set()
        for i in ids:
            out.update(eu_members if i == "EU" else [i])
        return sorted(out)

    snapshot = snapshot_date.isoformat()
    declared_duty: dict[str, dict] = {}   # digits -> key -> rec
    info_records: list[dict] = []
    seen_info = set()
    taxonomy: dict[tuple, int] = {}
    stats = {"rows": 0, "expired": 0, "future": 0, "unknown_types": 0}

    with measures_csv.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            stats["rows"] += 1
            mtype = r["measure__type__id"]
            taxonomy[(mtype, r["measure__type__description"])] = \
                taxonomy.get((mtype, r["measure__type__description"]), 0) + 1
            digits = r["commodity__code"].strip()
            end = (r["measure__effective_end_date"] or "").strip()
            if end and end != "#NA" and end < snapshot:
                stats["expired"] += 1
                continue
            origin = r["measure__geographical_area__id"].strip()
            origin_name = r["measure__geographical_area__description"].strip()
            add_code = (r["measure__additional_code__code"] or "").strip()
            if add_code == "#NA":
                add_code = ""
            duty = (r["measure__duty_expression"] or "").strip()
            if duty == "#NA":
                duty = ""
            conditions = _gb_split(r["measure__conditions"])
            footnotes = _gb_split(r["measure__footnotes"])
            excluded = expand_exclusions(
                _gb_split(r["measure__excluded_geographical_areas__ids"]))
            quota = (r["measure__quota__order_number"] or "").strip()
            if quota == "#NA":
                quota = ""
            reg_id = (r["measure__regulation__id"] or "").strip()
            if reg_id == "#NA":
                reg_id = ""

            if mtype in GB_MEASURE_DUTY:
                kind = GB_MEASURE_DUTY[mtype]
                if mtype == "103":
                    treatment = ("erga_omnes" if origin == GB_ERGA_OMNES
                                 else f"third_country_{origin}")
                elif kind.startswith("suspension"):
                    treatment = kind
                elif kind == "preference":
                    treatment = f"pref_{origin}"
                elif kind == "preference_end_use":
                    treatment = f"pref_end_use_{origin}"
                else:
                    treatment = kind
                start = (r["measure__effective_start_date"] or "").strip()
                is_future = bool(start and start != "#NA" and start > snapshot)
                if is_future:
                    # A future-start duty would collide with the current row
                    # for the same key; the near-daily rates refresh picks it
                    # up on its start date instead.
                    stats["future"] += 1
                    continue
                rec = _record(jur, revision, _display(digits), digits,
                              treatment, duty,
                              # Everything except the true erga-omnes UKGT
                              # needs entitlement/scope: preferences need
                              # proof of origin, origin-scoped 103s apply to
                              # their origin only, suspensions/end-use need
                              # the qualifying use.
                              conditional=(treatment != "erga_omnes"
                                           or bool(conditions)
                                           or bool(add_code)))
                rec["measure_type"] = mtype
                rec["origin_code"] = origin
                rec["origin_name"] = origin_name
                if excluded:
                    rec["excluded_origins"] = excluded
                if conditions:
                    rec["conditions"] = "; ".join(conditions)[:300]
                if footnotes:
                    rec["footnotes"] = footnotes[:12]
                if add_code:
                    rec["add_code"] = add_code
                    name = (r["measure__additional_code__description"] or "")
                    if name and name != "#NA":
                        rec["add_code_name"] = name[:80]
                if quota:
                    rec["quota_order_number"] = quota
                    rec["conditional"] = True
                if reg_id:
                    rec["regulation_id"] = reg_id
                key = (treatment, origin, add_code)
                slot = declared_duty.setdefault(digits, {})
                prev = slot.get(key)
                if prev is None or (prev.get("_start", "") < (start or "")):
                    rec["_start"] = start if start != "#NA" else ""
                    rec["_measure_sid"] = r["measure__sid"]
                    slot[key] = rec
            else:
                category = GB_MEASURE_INFO.get(mtype, "control")
                if mtype not in GB_MEASURE_INFO:
                    stats["unknown_types"] += 1
                label = r["measure__type__description"].strip()
                dedupe = (digits, mtype, origin, add_code, duty)
                if dedupe in seen_info:
                    continue
                seen_info.add(dedupe)
                rec = _record(jur, revision, _display(digits), digits,
                              f"{category}_{mtype}", duty,
                              informational=True, category=category,
                              conditional=bool(conditions or quota))
                rec["measure_type"] = mtype
                rec["measure_name"] = label[:90]
                rec["origin_code"] = origin
                rec["origin_name"] = origin_name
                if excluded:
                    rec["excluded_origins"] = excluded
                if add_code:
                    rec["add_code"] = add_code
                if quota:
                    rec["quota_order_number"] = quota
                if reg_id:
                    rec["regulation_id"] = reg_id
                rec["_measure_sid"] = r["measure__sid"]
                info_records.append(rec)

    # Taxonomy report: never silently absorb a new measure type (spec §25).
    print(f"[gb] measure-type inventory: {len(taxonomy)} types over "
          f"{stats['rows']:,} rows ({stats['expired']:,} expired dropped, "
          f"{stats['future']:,} future-start duty rows deferred)")
    unknown = sorted({t for (t, _d) in taxonomy}
                     - set(GB_MEASURE_DUTY) - set(GB_MEASURE_INFO))
    if unknown:
        print(f"[gb] NOTE: {len(unknown)} measure types outside the known "
              f"duty/info maps carried as informational 'control': "
              f"{', '.join(unknown)}")

    # ── coverage checks ──────────────────────────────────────────────
    leaves = _load_eu_leaf_tree(nomenclature_csv)
    covered = sum(1 for leaf in leaves
                  if any(k[0] == "erga_omnes"
                         for anc in _eu_ancestors(leaf)
                         for k in declared_duty.get(anc, {})))
    pct = 100.0 * covered / len(leaves)
    print(f"[gb] UKGT (erga omnes) coverage via ancestor walk: "
          f"{covered:,}/{len(leaves):,} leaves ({pct:.1f}%)")
    if pct < 95.0:
        raise SystemExit(f"ERROR: GB MFN leaf coverage {pct:.1f}% below the "
                         f"95% floor — inheritance or parsing regressed")

    # Sampled reconciliation against measures-on-declarable: the dataset's
    # own leaf expansion is ground truth for what the walk must resolve.
    dec = json.loads(declarable_json.read_text(encoding="utf-8"))
    sample = dec.get("sample_measures") or {}
    sid_to_code = {}
    commodities = declarable_json.parent / "commodities.csv"
    if sample and commodities.is_file():
        with commodities.open(newline="", encoding="utf-8-sig") as fh:
            for r in csv.DictReader(fh):
                sid_to_code[r["commodity__sid"]] = r["commodity__code"]
        kept_sids = ({rec["_measure_sid"] for recs in declared_duty.values()
                      for rec in recs.values()}
                     | {rec["_measure_sid"] for rec in info_records})
        checked = missing = 0
        for sid, msids in sample.items():
            code = sid_to_code.get(sid)
            if not code:
                continue
            reachable = set()
            for anc in _eu_ancestors(code):
                for rec in declared_duty.get(anc, {}).values():
                    reachable.add(rec["_measure_sid"])
            for rec in info_records:
                if rec["digits"] in _eu_ancestors(code):
                    reachable.add(rec["_measure_sid"])
            for msid in msids:
                if msid not in kept_sids:
                    continue          # expired/future rows we dropped
                checked += 1
                if msid not in reachable:
                    missing += 1
        miss_pct = 100.0 * missing / checked if checked else 0.0
        print(f"[gb] sampled reconciliation vs measures-on-declarable: "
              f"{checked:,} (sid, measure) pairs, {missing:,} unreachable "
              f"({miss_pct:.2f}%)")
        if checked and miss_pct > 1.0:
            raise SystemExit(
                f"ERROR: {miss_pct:.2f}% of sampled declarable measures are "
                f"NOT reachable via the ancestor walk — the declared-level "
                f"model diverges from the dataset's own leaf expansion")
    else:
        print("[gb] WARNING: no reconciliation sample available — the "
              "walk-vs-expansion proof did not run", file=sys.stderr)

    records = []
    for recs in declared_duty.values():
        for rec in recs.values():
            rec.pop("_start", None)
            rec.pop("_measure_sid", None)
            records.append(rec)
    for rec in info_records:
        rec.pop("_measure_sid", None)
    records.extend(info_records)

    # ── treatments file ──────────────────────────────────────────────
    origin_treatments: dict[str, dict] = {}
    for recs in declared_duty.values():
        for (treatment, origin_code, _ac), rec in recs.items():
            if treatment == "erga_omnes" or treatment in origin_treatments:
                continue
            kind = GB_MEASURE_DUTY.get(rec["measure_type"], "")
            origin_treatments[treatment] = {
                "treatment": treatment,
                "name": (f"Tariff preference — {rec['origin_name']}"
                         if kind == "preference" else
                         f"{kind.replace('_', ' ').title()} — "
                         f"{rec['origin_name']}"),
                "origin_countries": area_members(origin_code),
                "applies": None,
                "conditional": True,
                "legal_basis": f"UK tariff measure type {rec['measure_type']}",
            }
    tout = [{"treatment": "erga_omnes",
             "name": "UK Global Tariff (third-country duty)",
             "origin_countries": [], "applies": "all_origins",
             "conditional": False,
             "legal_basis": "Taxation (Cross-border Trade) Act 2018 / "
                            "UK tariff measure type 103"}]
    tout += [origin_treatments[k] for k in sorted(origin_treatments)]
    coverage = dict(GB_COVERAGE)
    # Day-fresh visibility: the UK dataset republishes near-daily and the
    # rates-only refresh reships these artifacts without a new corpus
    # revision, so the as-of line carries the exact dataset version.
    coverage["as_of"] = (f"{snapshot} · dataset {dec.get('version')}"
                        if dec.get("version") else snapshot)
    # The unified UK Customs Territory: England/Scotland/Wales (GB) plus
    # Northern Ireland (legally within it; Windsor dual-system for goods
    # entering NI), the Isle of Man, and the Channel Islands (UK-Crown
    # Dependencies Customs Union). Goods originating anywhere in it are in
    # free circulation for a GB import.
    coverage["applies_in"] = ["GG", "IM", "JE", "XI"]
    coverage["applies_in_note"] = (
        "These rates apply to imports into the UK customs territory — "
        "England, Scotland and Wales, with the Isle of Man and the Channel "
        "Islands (Jersey, Guernsey) inside the same customs union. Northern "
        "Ireland is legally part of the territory too, but goods entering "
        "Northern Ireland operate the Windsor Framework dual-system — see "
        "the Northern Ireland Online Tariff schedule.")
    overlay = load_overlay("gb")
    if overlay.get("flat_taxes"):
        coverage["flat_taxes"] = overlay["flat_taxes"]
    return records, tout, coverage


# ── Switzerland ──────────────────────────────────────────────────────────────

CH_ERGA_GRP = "100000"      # "Normal rate" — the Generaltarif country group

CH_COVERAGE = {
    "provides": [
        "The complete Swiss customs tariff at 8-digit depth from the BAZG "
        "Passar master data: the normal tariff (Generaltarif) plus every "
        "preferential rate with its tariff country group resolved to member "
        "origins — duty amounts verbatim (Swiss duties are predominantly "
        "specific, CHF per unit or weight; never converted to percentages).",
        "Per-code import VAT (standard, reduced and special rates from the "
        "master data), additional taxes (with min/max and units), customs "
        "privileges, permits and statistical keys as informational rows.",
        "Refreshed from every master-data regeneration (published daily "
        "when content changes); the as-of line shows the exact generation.",
    ],
    "excludes": [
        "Preferential origin-rule verification: a preferential rate is a "
        "candidate, not an entitlement — proof of origin is required.",
        "Tariff-quota entitlement: in-quota tariff numbers (K-Nr./Q. No.) "
        "are distinct codes shown as conditional; actual quota availability "
        "is operational data (e-quota), never assumed here.",
        "Customs privileges (reduced duty under end-use etc.) are listed "
        "separately, never merged into the ordinary rate.",
        "Ad-valorem equivalents for specific duties (a CHF-per-weight duty "
        "stays a specific duty; computing an equivalent needs the actual "
        "customs value and quantity).",
        "Fees and non-customs-law charges beyond those in the master data.",
    ],
    "source": "BAZG Passar master data (datahub.bazg.admin.ch, "
              "Swiss Federal Office for Customs and Border Security)",
}


def _ch_active(el, snapshot_iso: str) -> bool:
    vf = el.get("validFrom") or (el.findtext("validFrom") or "").strip()
    vt = el.get("validTo") or (el.findtext("validTo") or "").strip()
    return (not vf or vf <= snapshot_iso) and (not vt or vt >= snapshot_iso)


def _ch_rate_text(value: str, unit_note: str, weight: str) -> str:
    v = (value or "").strip()
    try:
        num = float(v)
    except ValueError:
        num = None
    if num == 0:
        return "Free"
    unit = (unit_note or "").strip()
    # gtBem reads "Fr. per piece(s)" / "Fr. je Stück" — fold the currency in.
    if unit[:3] in ("Fr.", "fr."):
        unit = unit[3:].strip()
    if unit:
        return f"CHF {v} {unit}"
    return f"CHF {v} ({weight} basis)" if weight else f"CHF {v}"


def build_ch(master_xml: Path, countries_xml: Path, jur: str, revision: str,
             nomenclature_csv: Path, snapshot_date, base_xml: Path,
             created: str = ""):
    """Swiss duty build: TariffMasterData (per-8-digit, exact inheritance)
    + CountryCodes group membership + base master data. Specific duties are
    preserved verbatim (spec: never forced into percentages); the normal
    tariff (group 100000) is the erga-omnes baseline; preferences are
    conditional on origin entitlement. Hard gates: the master commodity set
    must equal the nomenclature leaf set, every leaf must carry an NT rate,
    and the tree's own general-tariff column must agree with the master NT
    on a sample."""
    import xml.etree.ElementTree as _ET
    snapshot = snapshot_date.isoformat()

    # ── country groups (attribute-based; membership inverted from the
    #    per-country assignments, validity-filtered) ───────────────────
    geo_root = _ET.parse(countries_xml).getroot()
    def _S(t): return t.split("}")[-1]
    group_names: dict[str, str] = {}
    group_members: dict[str, list[str]] = {}
    for section in geo_root:
        if _S(section.tag) == "countryGroups":
            for g in section:
                if _ch_active(g, snapshot):
                    group_names[g.get("grpNr", "")] = g.get("nameEn") or                         g.get("nameDe") or g.get("grpNr", "")
        elif _S(section.tag) == "countries":
            for c in section:
                if not _ch_active(c, snapshot):
                    continue
                iso = c.get("isoCode", "")
                for a in c:
                    if _S(a.tag) == "countryGroupAssignment" and                             _ch_active(a, snapshot):
                        group_members.setdefault(a.get("grpNr", ""),
                                                 []).append(iso)
    if CH_ERGA_GRP not in group_names:
        raise SystemExit("ERROR: CountryCodes lacks group 100000 (Normal "
                         "rate) — schema changed?")

    # ── nomenclature: leaves, unit notes, tree general-tariff column ──
    leaves: dict[str, dict] = {}
    with nomenclature_csv.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            if (r.get("IS_LEAF") or "") == "1":
                leaves[r["GOODS_CODE"]] = {
                    "unit": (r.get("UNIT") or "").strip(),
                    "gt": (r.get("GT_RATE") or "").strip(),
                }
    if not leaves:
        raise SystemExit(f"ERROR: no leaves in {nomenclature_csv}")

    _QUOTA_RE = re.compile(r"quota|contingent|K-?Nr|Q\.\s*No", re.IGNORECASE)

    records: list[dict] = []
    stats = {"codes": 0, "skipped_export_only": 0, "expired": 0,
             "future_rates": 0, "nt_covered": 0, "gt_checked": 0,
             "gt_mismatch": 0}
    master_codes: set[str] = set()
    seen_treatments: dict[str, dict] = {}

    ctx = _ET.iterparse(master_xml, events=("end",))
    for _ev, el in ctx:
        if _S(el.tag) != "commodityCode":
            continue
        get = lambda k: (el.findtext(k) or "").strip()
        digits = get("value").replace(".", "")
        if (get("validForImport") != "true"
                or not _ch_active(el, snapshot)):
            stats["skipped_export_only"] += 1
            el.clear()
            continue
        master_codes.add(digits)
        stats["codes"] += 1
        info = leaves.get(digits, {"unit": "", "gt": ""})
        text_en = ""
        for t in el:
            if _S(t.tag) == "commodityCodeText":
                text_en = (t.findtext("textEn") or "").strip()
                break
        quota_line = bool(_QUOTA_RE.search(text_en))
        display = f"{digits[:4]}.{digits[4:]}"
        nt_seen = False

        # Baseline treatment set: privilege code 00 (ordinary) when present;
        # otherwise the lowest code — some lines are inherently use-bound
        # (e.g. "for slaughter" carries only privilege 01) and that set IS
        # the line's normal treatment, flagged conditional.
        priv_codes = sorted((pv.findtext("code") or "").strip()
                            for pv in el.iter()
                            if _S(pv.tag) == "customsPrivilegeCode")
        baseline = "00" if "00" in priv_codes else (priv_codes[0]
                                                    if priv_codes else "00")

        for priv in el.iter():
            if _S(priv.tag) != "customsPrivilegeCode":
                continue
            priv_code = (priv.findtext("code") or "").strip()
            is_normal = priv_code == baseline
            best_by_key: dict[tuple, dict] = {}
            for rate in priv:
                if _S(rate.tag) != "rate":
                    continue
                if not _ch_active(rate, snapshot):
                    vf = (rate.findtext("validFrom") or "").strip()
                    if vf and vf > snapshot:
                        stats["future_rates"] += 1
                    else:
                        stats["expired"] += 1
                    continue
                rtyp = (rate.findtext("type") or "").strip()
                grp = (rate.findtext("countryGrpNr") or "").strip()
                value = (rate.findtext("value") or "").strip()
                weight = (rate.findtext("weight") or "").strip()
                if rtyp == "NT" and grp == CH_ERGA_GRP:
                    treatment = "erga_omnes"
                elif rtyp == "NT":
                    treatment = f"third_country_{grp}"
                elif rtyp == "PR":
                    treatment = f"pref_{grp}"
                else:
                    treatment = f"rate_{rtyp.lower()}_{grp}"
                key = (treatment, grp)
                vf = (rate.findtext("validFrom") or "").strip()
                prev = best_by_key.get(key)
                if prev and prev["_vf"] >= vf:
                    continue
                best_by_key[key] = {
                    "_vf": vf, "treatment": treatment, "grp": grp,
                    "value": value, "weight": weight, "type": rtyp,
                    "dbr": (rate.findtext("dbr") or "").strip(),
                }
            for key, rr in best_by_key.items():
                rate_text = _ch_rate_text(rr["value"], info["unit"],
                                          rr["weight"])
                if is_normal:
                    rec = _record(jur, revision, display, digits,
                                  rr["treatment"], rate_text,
                                  conditional=(rr["treatment"] != "erga_omnes"
                                               or quota_line
                                               or baseline != "00"))
                    if baseline != "00":
                        rec["privilege_code"] = baseline
                else:
                    rec = _record(jur, revision, display, digits,
                                  f"privilege_{priv_code}_{rr['treatment']}",
                                  rate_text, informational=True,
                                  category="privilege", conditional=True)
                    rec["privilege_code"] = priv_code
                rec["origin_code"] = rr["grp"]
                rec["origin_name"] = group_names.get(rr["grp"], rr["grp"])
                if rr["weight"]:
                    rec["assessment_basis"] = rr["weight"]
                if quota_line and is_normal:
                    rec["quota_note"] = ("In-/out-of-quota tariff line — "
                                         "entitlement is operational data")
                records.append(rec)
                if is_normal and rr["treatment"] == "erga_omnes":
                    nt_seen = True
                    gt = info["gt"]
                    if gt:
                        stats["gt_checked"] += 1
                        try:
                            if abs(float(gt) - float(rr["value"])) > 0.005:
                                stats["gt_mismatch"] += 1
                        except ValueError:
                            pass
                if is_normal and rr["treatment"] != "erga_omnes" \
                        and rr["treatment"] not in seen_treatments:
                    seen_treatments[rr["treatment"]] = rr
                elif is_normal and rr["treatment"].startswith("pref_") \
                        and rr["treatment"] not in seen_treatments:
                    seen_treatments[rr["treatment"]] = rr
        if nt_seen:
            stats["nt_covered"] += 1

        # per-code VAT (current window)
        for vat in el:
            if _S(vat.tag) != "vatCode":
                continue
            code = (vat.findtext("code") or "").strip()
            rate_now = ""
            for vr in vat:
                if _S(vr.tag) == "vatRate" and _ch_active(vr, snapshot):
                    rate_now = (vr.findtext("rate") or "").strip()
            if rate_now:
                rec = _record(jur, revision, display, digits, "vat",
                              f"{rate_now}%", informational=True,
                              category="vat")
                rec["vat_code"] = code
                records.append(rec)

        # statistical keys + their permits/additional taxes (condensed)
        seen_ctl = set()
        for ctl in el:
            if _S(ctl.tag) != "controlCode":
                continue
            if not _ch_active(ctl, snapshot) or \
                    (ctl.findtext("validForImport") or "") != "true":
                continue
            key_val = (ctl.findtext("value") or "").strip()
            for t in ctl:
                if _S(t.tag) == "controlCodeText":
                    ktext = (t.findtext("textEn") or "").strip()
                    dd = ("stat_key", key_val)
                    if dd not in seen_ctl:
                        seen_ctl.add(dd)
                        rec = _record(jur, revision, display, digits,
                                      f"stat_key_{key_val}", "",
                                      informational=True,
                                      category="statistical_key")
                        rec["measure_name"] = f"Statistical key {key_val}: " \
                                              f"{ktext}"[:120]
                        records.append(rec)
            for sub in ctl.iter():
                st = _S(sub.tag)
                if st == "permit" and _ch_active(sub, snapshot):
                    ptext = (sub.findtext("textEn") or "").strip()
                    dd = ("permit", ptext)
                    if dd in seen_ctl or not ptext:
                        continue
                    seen_ctl.add(dd)
                    rec = _record(jur, revision, display, digits,
                                  "permit", "", informational=True,
                                  category="control", conditional=True)
                    rec["measure_name"] = ptext[:120]
                    records.append(rec)
                elif st == "additionalTax" and _ch_active(sub, snapshot):
                    code = (sub.findtext("code") or "").strip()
                    keyf = (sub.findtext("key") or "").strip()
                    dd = ("atax", code, keyf)
                    if dd in seen_ctl:
                        continue
                    seen_ctl.add(dd)
                    unit = (sub.findtext("unit") or "").strip()
                    rate = (sub.findtext("rate") or "").strip()
                    rec = _record(jur, revision, display, digits,
                                  f"additional_tax_{code}",
                                  f"{unit} {rate}".strip(),
                                  informational=True,
                                  category="additional_tax",
                                  conditional=(sub.findtext("optional")
                                               or "") == "true")
                    rec["measure_name"] = ((sub.findtext("textEn") or "")
                                           .strip())[:120]
                    mn = (sub.findtext("minValue") or "").strip()
                    mx = (sub.findtext("maxValue") or "").strip()
                    if mn or mx:
                        rec["min_max"] = f"{mn}–{mx}"
                    records.append(rec)
        el.clear()

    # ── hard gates ───────────────────────────────────────────────────
    leaf_set = set(leaves)
    only_master = sorted(master_codes - leaf_set)[:10]
    only_tree = sorted(leaf_set - master_codes)[:10]
    if master_codes != leaf_set:
        raise SystemExit(
            f"ERROR: master-data commodity set != nomenclature leaves "
            f"(master-only: {only_master}, tree-only: {only_tree})")
    pct = 100.0 * stats["nt_covered"] / len(leaf_set)
    print(f"[ch] normal-tariff coverage: {stats['nt_covered']:,}/"
          f"{len(leaf_set):,} leaves ({pct:.1f}%); tree-GT cross-check: "
          f"{stats['gt_checked']:,} compared, {stats['gt_mismatch']} "
          f"mismatches")
    if pct < 99.0:
        raise SystemExit(f"ERROR: CH normal-tariff leaf coverage {pct:.1f}% "
                         f"below the 99% floor")
    # Tree-GT vs applied NT divergence is EXPECTED where Switzerland
    # applies a lower rate than the statutory Generaltarif (industrial
    # tariffs abolished 2024-01-01: applied NT 0, statutory GT unchanged) —
    # reported above for visibility, never a gate.

    # ── treatments + coverage ────────────────────────────────────────
    tout = [{"treatment": "erga_omnes",
             "name": "Normal tariff (Generaltarif)",
             "origin_countries": [], "applies": "all_origins",
             "conditional": False,
             "legal_basis": "Customs Tariff Act (ZTG/LTaD), rate type NT"}]
    for treatment in sorted(seen_treatments):
        rr = seen_treatments[treatment]
        kind = ("Preferential tariff" if treatment.startswith("pref_")
                else "Country-specific normal tariff")
        tout.append({
            "treatment": treatment,
            "name": f"{kind} — {group_names.get(rr['grp'], rr['grp'])}",
            "origin_countries": sorted(set(group_members.get(rr["grp"], []))),
            "applies": None,
            "conditional": True,
            "legal_basis": f"BAZG tariff country group {rr['grp']}"
                           + (" · proof of origin (dbr)" if rr.get("dbr") == "J"
                              else ""),
        })
    coverage = dict(CH_COVERAGE)
    coverage["as_of"] = (f"{snapshot} · master data {created}" if created
                         else snapshot)
    coverage["applies_in"] = ["LI"]
    coverage["applies_in_note"] = (
        "These rates apply to imports into the Swiss customs territory — "
        "Switzerland and Liechtenstein form one customs area under the 1923 "
        "Customs Treaty; one tariff book serves both.")
    overlay = load_overlay("ch")
    if overlay.get("flat_taxes"):
        coverage["flat_taxes"] = overlay["flat_taxes"]
    return records, tout, coverage


# ── South Korea ──────────────────────────────────────────────────────────────

KR_COVERAGE = {
    "provides": [
        "The complete KCS tariff-rate set at 10-digit HSK depth — every rate "
        "class in the official schedule (basic, WTO concession, provisional, "
        "adjustment, quota, LDC, APTA/GSTP and every FTA schedule), with the "
        "applied non-preferential rate computed per the official UNI-PASS "
        "rate-application priority (세율적용 우선순위).",
        "Specific-duty components (unit tax amount, base price) verbatim, "
        "never converted to percentages.",
        "Korean and English nomenclature at every hierarchy level.",
    ],
    "excludes": [
        "FTA origin-rule verification: preference rows are candidates — proof "
        "of origin and agreement conditions are required.",
        "Tariff-rate-quota entitlement and operational quota status (in-quota "
        "rates are shown as conditional, never auto-selected).",
        "Partial-country scopes the bulk file does not enumerate (applicable-"
        "country classification 2 without a listed scope renders as "
        "conditional).",
        "Internal taxes beyond the flat VAT line (individual consumption tax, "
        "liquor tax, education taxes).",
        "Anti-dumping/countervailing and other tier-1 special measures are "
        "listed with their additive nature noted, never summed into a rate.",
    ],
    "source": "Korea Customs Service — Tariff Schedule by Item Number "
              "(data.go.kr 15051179) + UNI-PASS rate precedence",
}


def _kr_load_classes(classes_json: Path) -> list[dict]:
    import re as _re
    doc = json.loads(classes_json.read_text(encoding="utf-8"))
    rules = doc["rules"]
    for r in rules:
        r["_re"] = _re.compile(r["pattern"])
    return rules


def _kr_rule_for(rules: list[dict], code: str) -> dict | None:
    for r in rules:
        if r["_re"].fullmatch(code):
            return r
    return None


def _kr_rate_text(rate: str, unit_tax: str, base_price: str) -> str:
    parts = []
    if rate:
        parts.append(f"{rate}%")
    if unit_tax:
        parts.append(f"₩{unit_tax} per unit")
    if base_price:
        parts.append(f"(base price ₩{base_price})")
    return " ".join(parts)


def build_kr(rates_xlsx: Path, jur: str, revision: str,
             nomenclature_csv: Path, snapshot_date,
             classes_json: Path, rates_date: str = ""):
    """KR: every rate row declared at 10-digit HSK (inherit 'exact'), the
    applied non-preferential rate computed per the official UNI-PASS
    precedence, everything else carried as labeled candidates. Blank duty
    components stay NULL, never 0."""
    from acquire._xlsx_lite import read_sheets

    rules = _kr_load_classes(classes_json)
    snapshot = snapshot_date.isoformat()
    snap_num = snapshot.replace("-", "")

    leaves = []
    with nomenclature_csv.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            if (r.get("IS_LEAF") or "") == "1":
                leaves.append((r.get("GOODS_CODE") or "").strip())
    if not leaves:
        raise SystemExit(f"ERROR: no IS_LEAF rows in {nomenclature_csv}")

    # Both period sheets merged; identical rows deduped; expired rows dropped.
    seen_rows = set()
    per_hsk: dict[str, list[dict]] = {}
    unknown: dict[str, int] = {}
    stats = {"rows": 0, "expired": 0, "future": 0, "dupes": 0}
    for sheet, rows in read_sheets(str(rates_xlsx)).items():
        hdr = rows[0] if rows else {}
        if (hdr.get("A"), hdr.get("B")) != ("품목번호", "관세율구분"):
            raise SystemExit(f"ERROR: rates sheet {sheet!r} header changed: "
                             f"{ {k: hdr.get(k) for k in 'ABC'} }")
        for r in rows[1:]:
            stats["rows"] += 1
            hsk = (r.get("A") or "").strip()
            cls = (r.get("B") or "").strip()
            rate = (r.get("C") or "").strip()
            unit_tax = (r.get("D") or "").strip()
            base_price = (r.get("E") or "").strip()
            country_cls = (r.get("F") or "").strip()
            use_cls = (r.get("G") or "").strip()
            start = (r.get("H") or "").strip()
            end = (r.get("I") or "").strip()
            if end and end < snap_num:
                stats["expired"] += 1
                continue
            if start and start > snap_num:
                stats["future"] += 1
                continue
            key = (hsk, cls, rate, unit_tax, start, end, use_cls)
            if key in seen_rows:
                stats["dupes"] += 1
                continue
            seen_rows.add(key)
            per_hsk.setdefault(hsk, []).append({
                "cls": cls, "rate": rate, "unit_tax": unit_tax,
                "base_price": base_price, "country_cls": country_cls,
                "use_cls": use_cls, "start": start, "end": end,
                "rule": _kr_rule_for(rules, cls)})

    records: list[dict] = []
    treatments_seen: dict[str, dict] = {}
    applied_from = {"C-family": 0, "B": 0, "A": 0, "none": 0}
    for hsk, rows in per_hsk.items():
        display = f"{hsk[:4]}.{hsk[4:6]}-{hsk[6:]}"
        # applied non-preferential rate per official precedence
        def _num(x):
            try:
                return float(x["rate"])
            except (TypeError, ValueError):
                return None
        a = next((x for x in rows if x["rule"] and
                  x["rule"].get("treatment") == "basic"), None)
        b = next((x for x in rows if x["rule"] and
                  x["rule"].get("treatment") == "provisional"), None)
        cs = [x for x in rows if x["rule"] and x["rule"].get("treatment")
              in ("wto_concession", "wto_concession_alt")
              and _num(x) is not None]
        base = b or a                      # tier 6 beats tier 7
        chosen, source = base, ("B" if b else ("A" if a else "none"))
        if cs and base is not None and _num(base) is not None:
            c_best = min(cs, key=_num)
            if _num(c_best) < _num(base):
                chosen, source = c_best, "C-family"
        elif cs and base is None:
            chosen, source = min(cs, key=_num), "C-family"
        applied_from[source] += 1
        if chosen is not None:
            rec = _record(jur, revision, display, hsk, "erga_omnes",
                          _kr_rate_text(chosen["rate"], chosen["unit_tax"],
                                        chosen["base_price"]))
            rec["source_class"] = chosen["cls"]
            if chosen["use_cls"]:
                rec["use_class"] = chosen["use_cls"]
                rec["conditional"] = True
            records.append(rec)

        for x in rows:
            rule = x["rule"]
            rate_text = _kr_rate_text(x["rate"], x["unit_tax"], x["base_price"])
            if rule is None:
                unknown[x["cls"]] = unknown.get(x["cls"], 0) + 1
                rec = _record(jur, revision, display, hsk,
                              f"unknown_{x['cls']}", rate_text,
                              informational=True, category="unknown",
                              conditional=True)
                rec["rate_class"] = x["cls"]
                records.append(rec)
                continue
            tier = rule.get("tier")
            if rule.get("family"):                      # FTA (tier 2)
                treatment = f"pref_{x['cls']}"
                rec = _record(jur, revision, display, hsk, treatment,
                              rate_text, conditional=True)
                rec["rate_class"] = x["cls"]
                # family name lives once in the treatments map, not on all
                # ~358k rows
                records.append(rec)
                treatments_seen.setdefault(treatment, {
                    "treatment": treatment,
                    "name": f"{rule['family']} — schedule {x['cls']}",
                    "origin_countries": rule.get("origins", []),
                    "applies": None, "conditional": True,
                    "legal_basis": "Customs Act / FTA implementation "
                                   "(UNI-PASS tier 2)"})
            elif rule.get("treatment") in ("basic", "provisional",
                                           "wto_concession",
                                           "wto_concession_alt"):
                # raw applied-rate inputs: informational so the computed
                # erga_omnes stays the single best-rate carrier
                rec = _record(jur, revision, display, hsk,
                              rule["treatment"], rate_text,
                              informational=True, category="rate_basis")
                rec["rate_class"] = x["cls"]
                records.append(rec)
            else:
                # Class-scoped treatment names: APTA/GSTP/quota classes come
                # in sub-schedule variants (E2A1 quota tranche vs E2A2) that
                # must stay distinguishable rows, exactly like FTA staging
                # codes.
                treatment = (rule["treatment"] if x["cls"] ==
                             rule["treatment"] else
                             f"{rule['treatment']}_{x['cls'].lower()}")
                conditional = bool(rule.get("conditional")
                                   or x["use_cls"] or x["country_cls"] == "2")
                informational = tier in (0, 1) or rule.get("category") in (
                    "quota", "adjustment")
                rec = _record(jur, revision, display, hsk, treatment,
                              rate_text,
                              informational=informational,
                              category=rule.get("category", "duty")
                              if informational else "duty",
                              conditional=conditional)
                rec["rate_class"] = x["cls"]
                if rule.get("additive"):
                    rec["additive"] = True
                if x["use_cls"]:
                    rec["use_class"] = x["use_cls"]
                records.append(rec)
                if not informational and treatment not in treatments_seen:
                    treatments_seen[treatment] = {
                        "treatment": treatment,
                        "name": (rule["name"] if x["cls"] == rule["treatment"]
                                 else f"{rule['name']} — schedule {x['cls']}"),
                        "origin_countries": rule.get("origins", []),
                        "applies": None, "conditional": True,
                        "legal_basis": f"Customs Act (UNI-PASS tier {tier})"}

    if unknown:
        print(f"[kr] NOTE: {len(unknown)} UNKNOWN rate classes carried "
              f"informationally: {sorted(unknown)} — extend "
              f"config/kr_rate_classes.json after checking UNI-PASS")
    print(f"[kr] {stats['rows']:,} rate rows ({stats['expired']:,} expired, "
          f"{stats['future']:,} future dropped, {stats['dupes']:,} "
          f"cross-sheet dupes); applied rate from {applied_from}")

    # Residual same-key duplicates (one class active twice at the snapshot —
    # staged windows/quota tranches): first row stands, later ones stay
    # visible as informational variants rather than tripping the collision
    # gate or double-counting in best-rate.
    seen_keys: set = set()
    demoted = 0
    for r in records:
        if r.get("informational"):
            continue
        key = (r["digits"], r["treatment"], r.get("origin_code"),
               r.get("add_code"))
        if key in seen_keys:
            r["informational"] = True
            r["category"] = "rate_variant"
            demoted += 1
        else:
            seen_keys.add(key)
    if demoted:
        print(f"[kr] {demoted} same-class variant rows carried as "
              f"informational rate_variant")

    erga_by_hsk = {r["digits"] for r in records if r["treatment"] == "erga_omnes"}
    covered = sum(1 for leaf in leaves if leaf in erga_by_hsk)
    pct = 100.0 * covered / len(leaves)
    print(f"[kr] applied-rate coverage: {covered:,}/{len(leaves):,} leaves "
          f"({pct:.1f}%)")
    if pct < 99.0:
        raise SystemExit(f"ERROR: KR applied-rate coverage {pct:.1f}% below "
                         f"the 99% floor — every HSK carries an A row in the "
                         f"source, so a miss means parsing regressed")

    tout = [{"treatment": "erga_omnes",
             "name": "Applied non-preferential rate (per the official "
                     "UNI-PASS rate-application priority)",
             "origin_countries": [], "applies": "all_origins",
             "conditional": False,
             "legal_basis": "Customs Act; 세율적용 우선순위 (UNI-PASS)"}]
    tout += [treatments_seen[k] for k in sorted(treatments_seen)]
    coverage = dict(KR_COVERAGE)
    coverage["as_of"] = (f"{snapshot} · 관세율표 {rates_date}"
                        if rates_date else snapshot)
    overlay = load_overlay("kr")
    if overlay.get("flat_taxes"):
        coverage["flat_taxes"] = overlay["flat_taxes"]
    return records, tout, coverage


# ── Taiwan ───────────────────────────────────────────────────────────────────

TW_COVERAGE = {
    "provides": [
        "The complete three-column Customs Import Tariff at 11-digit CCC "
        "depth: Column I (WTO members and reciprocal territories — the "
        "applied rate for most origins), Column II (preferential — FTA "
        "partners, ECFA, LDCs; per-line origin lists from the schedule "
        "itself), Column III (general rate for other origins).",
        "Specific and compound duties verbatim (NT$/unit, 'whichever is "
        "higher'), never converted to percentages.",
        "Traditional Chinese and English nomenclature at every level, and "
        "the schedule's levy-rule markers (稽徵規定).",
    ],
    "excludes": [
        "FTA origin-rule verification: Column II rows are candidates — "
        "proof of origin and agreement conditions are required.",
        "Tariff-rate-quota entitlement and operational status (levy marker "
        "R flags TRQ lines; in-quota administration is not modeled).",
        "Anti-dumping/countervailing case rates and provisional 機動 "
        "adjustments outside the published schedule.",
        "Internal taxes beyond the flat lines (commodity tax, tobacco and "
        "alcohol taxes on specific goods).",
    ],
}

# 稽徵規定 (levy-rule) markers seen in the schedule; unknown codes pass
# through verbatim with a generic label.
TW_LEVY_GLOSSARY = {
    "R": "tariff-rate quota line",
    "T": "tobacco/alcohol tax applies",
    "T*": "tobacco/alcohol tax applies (variant)",
    "Z": "levy rule Z",
    "G": "levy rule G",
    "L": "levy rule L",
    "L*": "levy rule L (variant)",
    "B": "levy rule B",
    "N": "levy rule N",
}

_TW_COL2_GROUP = re.compile(r"([^()]+?)\(([^)]+)\)")


def _tw_pref_treatment(origins: list[str]) -> str:
    """Deterministic, self-describing treatment key for a Column II origin
    set — stable across revisions so the consumer's keys don't churn."""
    return "pref_" + "-".join(o.lower().replace("*", "") for o in sorted(origins))


def build_tw(main_xls: Path, jur: str, revision: str,
             nomenclature_csv: Path):
    """TW: one row per 11-digit CCC code in the MAIN portal xls, carrying
    all three duty columns. erga_omnes = Column I (the applied rate for WTO
    members — practically all origins); Column II preferential groups become
    conditional treatments keyed by their origin set; Column III rides as an
    informational general rate. Blank components stay NULL, never 0."""
    from acquire.tw_customs import parse_main_xls

    leaves = []
    with nomenclature_csv.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            if (r.get("IS_LEAF") or "") == "1":
                leaves.append((r.get("GOODS_CODE") or "").strip())
    if not leaves:
        raise SystemExit(f"ERROR: no IS_LEAF rows in {nomenclature_csv}")

    rows = parse_main_xls(main_xls)
    records: list[dict] = []
    treatments_seen: dict[str, dict] = {}
    col1_missing = 0

    def display(digits: str) -> str:
        return (f"{digits[:4]}.{digits[4:6]}.{digits[6:8]}."
                f"{digits[8:10]}-{digits[10:]}")

    for row in rows:
        code = row["code"]
        disp = display(code)
        if row["col1"]:
            records.append(_record(jur, revision, disp, code, "erga_omnes",
                                   row["col1"]))
        else:
            col1_missing += 1
        # Column II: 1..3 "rate (origins)" groups per cell.
        c2 = row["col2"]
        if c2:
            groups = _TW_COL2_GROUP.findall(c2)
            leftover = _TW_COL2_GROUP.sub("", c2).strip()
            if not groups or leftover:
                raise SystemExit(f"ERROR: unparseable Column II cell for "
                                 f"{code}: {c2!r} — format changed")
            for rate, origins_raw in groups:
                origins = [o.strip() for o in origins_raw.split(",") if o.strip()]
                treatment = _tw_pref_treatment(origins)
                records.append(_record(jur, revision, disp, code, treatment,
                                       rate.strip(), conditional=True))
                treatments_seen.setdefault(treatment, {
                    "treatment": treatment,
                    "name": "Preferential (Column II) — " + ", ".join(sorted(origins)),
                    "origin_countries": sorted(origins),
                    "applies": None, "conditional": True,
                    "legal_basis": "Customs Import Tariff, Column II "
                                   "(FTA/ECFA/LDC preferential)"})
        if row["col3"]:
            records.append(_record(jur, revision, disp, code,
                                   "general_non_wto", row["col3"],
                                   informational=True, category="general_rate"))
        if row["levy"]:
            note = "; ".join(TW_LEVY_GLOSSARY.get(tok, f"levy rule {tok}")
                             for tok in row["levy"].split())
            records.append(_record(jur, revision, disp, code, "levy_rule",
                                   f"{row['levy']} ({note})",
                                   informational=True, category="levy_rule",
                                   conditional=True))

    # Leaf-set integrity: the nomenclature CSV and the rates both come from
    # the same xls, so any mismatch means a parsing regression.
    xls_codes = {r["code"] for r in rows}
    missing = [l for l in leaves if l not in xls_codes]
    if missing:
        raise SystemExit(f"ERROR: {len(missing)} nomenclature leaves absent "
                         f"from the rates parse (first: {missing[:5]})")

    covered = sum(1 for r in records if r["treatment"] == "erga_omnes")
    pct = 100.0 * covered / len(leaves)
    print(f"[tw] {len(records):,} records; Column I coverage "
          f"{covered:,}/{len(leaves):,} leaves ({pct:.1f}%); "
          f"{len(treatments_seen)} Column II origin-set treatments; "
          f"{col1_missing} rows without a Column I rate")
    if pct < 99.5:
        raise SystemExit(f"ERROR: TW Column I coverage {pct:.1f}% below the "
                         f"99.5% floor — every CCC line carries a Column I "
                         f"rate in the source, so a miss means parsing "
                         f"regressed")

    tout = [{"treatment": "erga_omnes",
             "name": "Column I — WTO members and reciprocal territories "
                     "(the applied rate for most origins)",
             "origin_countries": [], "applies": "all_origins",
             "conditional": False,
             "legal_basis": "Customs Import Tariff of the Republic of "
                            "China, Column I"},
            {"treatment": "general_non_wto",
             "name": "Column III — general rate (origins outside Columns "
                     "I/II)",
             "origin_countries": [], "applies": None, "conditional": True,
             "legal_basis": "Customs Import Tariff, Column III"},
            {"treatment": "levy_rule",
             "name": "稽徵規定 levy-rule marker",
             "origin_countries": [], "applies": None, "conditional": True,
             "legal_basis": "Customs Import Tariff, collection provisions"}]
    tout += [treatments_seen[k] for k in sorted(treatments_seen)]
    coverage = dict(TW_COVERAGE)
    coverage["as_of"] = f"{revision} · CCC schedule ({main_xls.name})"
    overlay = load_overlay("tw")
    if overlay.get("flat_taxes"):
        coverage["flat_taxes"] = overlay["flat_taxes"]
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


# ── Shared helpers: hand-acquired static editions (SG / MY / VN) ─────────────
#
# These three books print their duties as text cells on one canonical CSV,
# like DO. What the cells say is carried; what they do not say is never
# supplied. Three record shapes come out of them:
#
#   * representable rate  -> an ordinary record. Specific and compound duties
#     keep amount, currency and unit in rate_text verbatim and in a structured
#     `components` list; they are never turned into an ad-valorem figure. A
#     compound "N% and <amount>" follows classify_rate's existing compound
#     convention (rate_kind 'compound', ad_valorem = the percentage component
#     only, so the UI labels it partial).
#   * text that is not a representable rate (a cross-reference, a multiple of
#     another rate, a specific amount with no unit, an unrecognised pattern,
#     a blank where the book must print something) -> the KR unknown-class
#     mechanism: treatment `unknown_<column treatment>`, informational,
#     category "unknown", conditional, rate_text verbatim, plus
#     `needs_review` (the reason) and `source_column`. It is never an MFN row,
#     never `best`, never 0.
#   * a NOTE line per reason at build time, like build_kr's unknown-class
#     tripwire, so a new pattern is seen rather than absorbed.

# A leaf's MFN must be representable on at least this share of leaves, after
# taking out leaves whose MFN cell is a KNOWN non-rate (VN's Chapter 98
# cross-references). On the current editions the figure is 100% (SG, MY) and
# 100% (VN, once its four malformed Chapter 98 codes are repaired), so a drop
# below the floor means parsing regressed, not that the book changed tone.
STATIC_MFN_FLOOR_PCT = 99.0

_PCT_TERM = re.compile(r"(\d+(?:\.\d+)?)\s*%")
_NIL_WORDS = ("free", "nil")


def _read_canonical(csv_path: Path, required: tuple, tag: str) -> list[dict]:
    """Canonical CSV -> list of whitespace-trimmed, NFC-normalized rows. A
    missing column is a schema change and must be reviewed, not ingested as
    blanks (a blank SG duty column would otherwise read as nil everywhere)."""
    import unicodedata
    with csv_path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        missing = [c for c in required if c not in (reader.fieldnames or [])]
        if missing:
            raise SystemExit(f"ERROR: {tag} CSV {csv_path} lacks column(s) "
                             f"{missing} — the header changed; review it "
                             f"before ingesting")
        return [{k: unicodedata.normalize("NFC", (v or "").strip())
                 for k, v in r.items() if k} for r in reader]


def _unrepresentable(jur, revision, code, digits, base_treatment, text,
                     reason, column, note=""):
    """Carry a cell that is not a representable rate, verbatim and flagged
    (build_kr's unknown-class mechanism). Never an ad-valorem figure."""
    rec = _record(jur, revision, code, digits, f"unknown_{base_treatment}",
                  text, informational=True, category="unknown",
                  conditional=True)
    rec["rate_kind"] = "other" if (text or "").strip() else "none"
    rec.pop("ad_valorem", None)
    rec["needs_review"] = reason
    rec["source_column"] = column
    if note:
        rec["note"] = note
    return rec


def _parse_duty_expr(text: str, currency_re: str, currency: str,
                     unit_of_quantity: str = "",
                     allow_alternatives: bool = False) -> dict:
    """Parse a printed duty/tax cell into components without converting
    anything. Grammar (whole cell must match, else 'unrecognised'):

        term   := N%  |  (<currency> AMOUNT | N cents)
                          [per <unit> | for every <unit> | each]
        expr   := term ( and term )*            -> combine 'sum'
               |  term or term w.i.t.h[.]       -> combine 'greater_of'
        cell   := expr ( / expr )*              -> combine 'alternatives'
                                                   (only if allow_alternatives)

    A money term without its own 'per'/'each' takes `unit_of_quantity` —
    pass it ONLY where the legal text says the amount is per the schedule's
    unit of quantity (MY customs duty, Customs Duties Order 2025 para 3(b));
    otherwise the result is 'unit_not_stated'.

    -> {"components": [...], "combine": None|'sum'|'greater_of'|
        'alternatives', "text": rendered rate_text} or {"error": reason}."""
    t = " ".join((text or "").split())
    if allow_alternatives and "/" in t:
        alts = [a.strip() for a in t.split("/")]
        out_c, out_t = [], []
        for a in alts:
            sub = _parse_duty_expr(a, currency_re, currency, unit_of_quantity)
            if "error" in sub:
                return sub
            out_c.extend(sub["components"])
            out_t.append(sub["text"])
        return {"components": out_c, "combine": "alternatives",
                "text": " / ".join(out_t)}
    greater = False
    m = re.fullmatch(r"(.*?)\s+w\.i\.t\.h\.?", t)
    if m:
        t, greater = m.group(1), True
    # Split on and/or ONLY where a new rate term starts: a unit clause may
    # itself contain the words ("…Environmental Protection and Management
    # (Vehicular Emissions) Regulations", "every gram or part thereof").
    term_start = (r"(?=\d+(?:\.\d+)?\s*%|" + currency_re + r"\s?\d"
                  r"|\d+(?:\.\d+)?\s+cents\b)")
    parts = re.split(r"\s+(and|or)\s+" + term_start, t)
    terms, ops = parts[0::2], set(parts[1::2])
    if len(ops) > 1 or (ops == {"or"}) != greater:
        return {"error": "unrecognised"}
    comps, rendered = [], []
    for term in terms:
        pm = _PCT_TERM.fullmatch(term)
        if pm:
            comps.append({"type": "ad_valorem", "percent": float(pm.group(1))})
            rendered.append(term)
            continue
        # "<currency> 16.00" or "58.9 cents"; unit clause "per …",
        # "for every …" or "each".
        mm = re.fullmatch(r"(?:" + currency_re + r"\s?(\d[\d,]*(?:\.\d+)?)"
                          r"|(\d+(?:\.\d+)?)\s+cents)"
                          r"(?:\s+(per\s+.+|for every\s+.+|each))?", term)
        if not mm:
            return {"error": "unrecognised"}
        per = mm.group(3) or ""
        if per:
            # "per X" -> "X"; "for every X" -> "every X"
            unit = "each" if per == "each" else per[4:].strip()
            source = "stated"
            rendered.append(term)
        elif unit_of_quantity:
            unit, source = unit_of_quantity, "unit_of_quantity"
            rendered.append(f"{term} per {unit_of_quantity}")
        else:
            return {"error": "unit_not_stated"}
        comp = {"type": "specific", "currency": currency, "per": unit,
                "unit_source": source}
        if mm.group(1) is not None:
            comp["amount"] = float(mm.group(1).replace(",", ""))
        else:
            # amount in the currency's major unit (100 cents = 1), exact
            # decimal shift; the printed figure stays alongside
            comp["amount"] = round(float(mm.group(2)) / 100, 6)
            comp["as_printed"] = f"{mm.group(2)} cents"
        comps.append(comp)
    if greater:
        text_out = " or ".join(rendered) + ", whichever is the higher"
        combine = "greater_of"
    else:
        text_out = " and ".join(rendered)
        combine = "sum" if len(comps) > 1 else None
    return {"components": comps, "combine": combine, "text": text_out}


def _expr_record(jur, revision, code, digits, treatment, cell, parsed, *,
                 informational=False, category="duty", conditional=False):
    """Record for a parsed duty expression. rate_kind/ad_valorem follow
    classify_rate's contract; a 'sum' with exactly one percentage becomes
    'compound' (ad_valorem = that component only); 'greater_of' and
    'alternatives' never carry an ad_valorem."""
    rec = _record(jur, revision, code, digits, treatment, parsed["text"],
                  informational=informational, category=category,
                  conditional=conditional)
    comps, combine = parsed["components"], parsed["combine"]
    if not comps and parsed["text"].lower() in _NIL_WORDS:
        rec["rate_kind"], rec["ad_valorem"] = "free", 0.0    # "NIL" / "Free"
    if any(c["type"] == "specific" for c in comps) or combine:
        rec["components"] = comps
        if combine:
            rec["combine"] = combine
        pcts = [c for c in comps if c["type"] == "ad_valorem"]
        if combine == "sum" and len(pcts) == 1:
            rec["rate_kind"] = "compound"
            rec["ad_valorem"] = round(pcts[0]["percent"] / 100, 6)
        else:
            rec["rate_kind"] = "other"
            rec.pop("ad_valorem", None)
    if parsed["text"] != " ".join(cell.split()):
        rec["source_text"] = cell
    return rec


def _static_mfn_gate(tag: str, leaves: list[str], records: list[dict],
                     known_non_rate: set[str]) -> None:
    """Every leaf must be ACCOUNTED for (an MFN row or a flagged MFN row), and
    representable MFN coverage — excluding known non-rate cells — must clear
    STATIC_MFN_FLOOR_PCT."""
    have = {r["digits"] for r in records if r["treatment"] == "MFN"}
    flagged = {r["digits"] for r in records if r["treatment"] == "unknown_MFN"}
    unaccounted = [d for d in leaves if d not in have and d not in flagged]
    if unaccounted:
        raise SystemExit(f"ERROR: {len(unaccounted)} {tag} leaves have neither "
                         f"an MFN record nor a flagged one (first: "
                         f"{unaccounted[:5]}) — a leaf was silently dropped")
    denom = len(leaves) - len(known_non_rate & set(leaves))
    covered = sum(1 for d in leaves if d in have)
    pct = 100.0 * covered / denom if denom else 0.0
    print(f"[{tag.lower()}] MFN coverage: {covered:,}/{len(leaves):,} leaves "
          f"({pct:.2f}% of {denom:,} after {len(leaves) - denom:,} known "
          f"non-rate cells); {len(flagged):,} leaves carry a flagged MFN cell")
    if pct < STATIC_MFN_FLOOR_PCT:
        raise SystemExit(f"ERROR: {tag} representable MFN coverage {pct:.2f}% "
                         f"below the {STATIC_MFN_FLOOR_PCT}% floor — parsing "
                         f"regressed")


def _flag_report(tag: str, records: list[dict]) -> None:
    by_reason: dict[tuple, int] = {}
    for r in records:
        if r.get("needs_review"):
            k = (r["source_column"], r["needs_review"])
            by_reason[k] = by_reason.get(k, 0) + 1
    for (col, reason), n in sorted(by_reason.items()):
        print(f"[{tag}] NOTE: {n:,} {col} cell(s) not representable "
              f"({reason}) — carried verbatim as informational "
              f"category 'unknown'")


def _unknown_treatments(records: list[dict], names: dict[str, str]) -> list[dict]:
    seen = sorted({r["treatment"] for r in records
                   if r.get("category") == "unknown"})
    return [{"treatment": t,
             "name": names.get(t, f"{t[len('unknown_'):]} cell as printed — "
                               f"not a representable rate"),
             "origin_countries": [], "applies": None, "conditional": True,
             "category": "unknown",
             "note": "Carried verbatim for review; never used as a rate."}
            for t in seen]


def _nonleaf_rate_note(tag: str, rows: list[dict], cols: tuple) -> None:
    odd = [r["GOODS_CODE"] for r in rows
           if r.get("GOODS_CODE") and r.get("IS_LEAF") != "1"
           and any(r.get(c) for c in cols)]
    if odd:
        print(f"[{tag}] WARNING: {len(odd)} non-leaf coded row(s) carry a "
              f"rate and were not emitted (first: {odd[:5]}) — the book "
              f"prints rates on leaves only, so check the parser",
              file=sys.stderr)


# ── Singapore ────────────────────────────────────────────────────────────────

SG_COVERAGE = {
    "provides": [
        "Customs duty (STCCED column 5, 'Full') for every 8-digit line of the "
        "STCCED 2022: nil on every line except beer (2203) and samsu "
        "(2208.90), whose specific duties — S$ per litre of alcohol — are "
        "shown verbatim, never converted to percentages.",
        "The 'Pref' column (STCCED column 6) where the book prints one. The "
        "book does not say which origins or arrangement it covers, so it is "
        "shown as an unverified preference that never applies to a chosen "
        "origin.",
        "Excise duty (STCCED column 7) as an informational tax line, ad "
        "valorem or specific, verbatim.",
    ],
    "excludes": [
        "Free-trade-agreement schedules (separate publications; Singapore "
        "levies customs duty on almost nothing, so they matter only for "
        "beer and samsu).",
        "Goods and Services Tax on imports (levied under the GST Act, not "
        "printed in the STCCED).",
        "Nil customs duty is read from a BLANK column-5 cell. The STCCED does "
        "not define a blank; the basis is Singapore Customs, which names four "
        "dutiable categories (intoxicating liquors, tobacco products, motor "
        "vehicles, petroleum products and biodiesel blends) and states: 'Goods "
        "not subject to customs or excise duty are non-dutiable, although GST "
        "may still apply unless exempted.' Source: Singapore Customs, 'Duties and Dutiable Goods Overview' (customs.gov.sg/businesses/valuation-duties-taxes-and-fees/duties-and-dutiable-goods/, last updated 9 March 2026).",
        "Duty or excise text the build could not read is carried verbatim "
        "and flagged for review, never shown as a rate.",
    ],
    "source": "Singapore Customs — Singapore Trade Classification, Customs "
              "and Excise Duties (STCCED) 2022 (PDF)",
}
SG_REQUIRED = ("GOODS_CODE", "DISPLAY", "IS_LEAF", "DUTY_FULL", "DUTY_PREF",
               "EXCISE")


def _sg_parse(cell: str) -> dict:
    if cell.lower() in _NIL_WORDS:
        return {"components": [], "combine": None, "text": cell}
    # "$" is the book's only currency; its sole currency reference is the
    # VAL unit of quantity, "Unit of Value of One Singapore Dollar".
    return _parse_duty_expr(cell, r"\$", "SGD")


def build_sg(csv_path: Path, jur: str, revision: str):
    """SG: STCCED 2022 — FULL (MFN), PREF and EXCISE columns per 8-digit
    leaf.

    BLANK = NIL. Every leaf with a blank DUTY_FULL is emitted as an explicit
    'Free' MFN row (rate_basis 'blank_nil'); otherwise 11,415 of 11,423 lines
    would show "no rate". The STCCED itself does not state this, and that is
    recorded here rather than smoothed over: the STCCED 2022 front matter (PDF pages
    5-18 — Preface, General Interpretative Rules, Abbreviations and Symbols,
    Units of Quantity, the section/chapter list) contains NO statement that a
    blank duty cell means nil, and no legend for the columns at all (the
    whole 655-page text was searched for 'nil', 'blank', 'preferen*',
    'Commonwealth' and 'PREF' outside the column header: nothing). The
    reading rests on the book's structure, not on a definition: column (5)
    'CUSTOMS DUTY — FULL' is printed on only 8 of 11,423 lines (beer and
    samsu), and the only place the book speaks of dutiability it defers to
    another instrument (heading 98.92: "other than dutiable goods falling
    within the Customs Duties Order"). The book does use the word 'Free' —
    but only in the Pref column of those same 8 lines — so a blank Full cell
    is NOT a printed 'Free', and each such record says so (rate_basis
    'blank_nil'). Because a parse regression that blanked the column would
    masquerade as nil, an all-blank column fails the build.

    THE BASIS IS SINGAPORE CUSTOMS, not the book: its 'Duties and Dutiable
    Goods Overview' names four dutiable categories (intoxicating liquors,
    tobacco products, motor vehicles, petroleum products and biodiesel blends)
    and states "Goods not subject to customs or excise duty are non-dutiable,
    although GST may still apply unless exempted." Of those, only liquor
    carries CUSTOMS duty in column (5); tobacco, vehicles and petroleum are
    excise (column 7), emitted here as informational tax. See SOURCES.md.

    PREF: the book never says which origins or arrangement column (6)
    'PREF' serves. Singapore Customs does: preferential tariffs under its free
    trade agreements "allow importers to pay lower or zero customs duty on
    certain dutiable goods" -- stout or porter, beer including ale, medicated
    samsu and other samsu -- for originating goods with proof of origin
    (E-ATIGA Form D, ACFTA Form E, CSFTA, RCEP among others). No source
    enumerates every partner, so the treatment carries NO origins and
    transcription_pending: it never applies to a chosen origin until that list
    is transcribed."""
    rows = _read_canonical(csv_path, SG_REQUIRED, "SG")
    leaves = [r for r in rows if r["GOODS_CODE"] and r["IS_LEAF"] == "1"]
    if not leaves:
        raise SystemExit(f"ERROR: no IS_LEAF rows in {csv_path}")
    if not any(r["DUTY_FULL"] for r in leaves):
        raise SystemExit("ERROR: DUTY_FULL is blank on every SG leaf — the "
                         "book prints beer/samsu duties, so an all-blank "
                         "column means the parser lost it; blank=nil would "
                         "publish every line as duty-free")
    _nonleaf_rate_note("sg", rows, ("DUTY_FULL", "DUTY_PREF", "EXCISE"))

    records: list[dict] = []
    for r in leaves:
        digits = bhc._digits_only(r["GOODS_CODE"])
        code = r["DISPLAY"] or digits
        full = r["DUTY_FULL"]
        if not full:
            rec = _record(jur, revision, code, digits, "MFN", "Free")
            rec["rate_basis"] = "blank_nil"
            records.append(rec)
        else:
            p = _sg_parse(full)
            records.append(
                _unrepresentable(jur, revision, code, digits, "MFN", full,
                                 p["error"], "DUTY_FULL") if "error" in p
                else _expr_record(jur, revision, code, digits, "MFN", full, p))
        pref = r["DUTY_PREF"]
        if pref:
            p = _sg_parse(pref)
            records.append(
                _unrepresentable(jur, revision, code, digits, "PREF", pref,
                                 p["error"], "DUTY_PREF") if "error" in p
                else _expr_record(jur, revision, code, digits, "PREF", pref,
                                  p, conditional=True))
        exc = r["EXCISE"]
        if exc:
            p = _sg_parse(exc)
            records.append(
                _unrepresentable(jur, revision, code, digits, "EXCISE", exc,
                                 p["error"], "EXCISE") if "error" in p
                else _expr_record(jur, revision, code, digits, "EXCISE", exc,
                                  p, informational=True, category="tax"))

    _flag_report("sg", records)
    _static_mfn_gate("SG", [bhc._digits_only(r["GOODS_CODE"]) for r in leaves],
                     records, set())

    tout = [
        {"treatment": "MFN",
         "name": "Customs duty — full rate (all origins)",
         "origin_countries": [], "applies": "all_origins",
         "conditional": False,
         "legal_basis": "STCCED 2022, column (5) 'Customs Duty — Full'; "
                        "dutiable goods are those within the Customs Duties "
                        "Order (STCCED heading 98.92)",
         "note": "Lines with no printed full rate are shown as nil (Free). "
                 "The STCCED does not define a blank cell; Singapore Customs "
                 "states that goods outside its four dutiable categories "
                 "(intoxicating liquors, tobacco products, motor vehicles, "
                 "petroleum products and biodiesel blends) are non-dutiable, "
                 "and of those only liquor carries customs duty in this column.",
         "source": "Singapore Customs, 'Duties and Dutiable Goods Overview' (customs.gov.sg/businesses/valuation-duties-taxes-and-fees/duties-and-dutiable-goods/, last updated 9 March 2026)"},
        {"treatment": "PREF",
         "name": "Customs duty — FTA preferential rate (originating goods)",
         "origin_countries": [], "applies": None, "conditional": True,
         "transcription_pending": True,
         "legal_basis": "STCCED 2022, column (6) 'Customs Duty — Pref'",
         "note": "Singapore's free trade agreements allow lower or zero customs "
                 "duty on stout or porter, beer including ale, medicated samsu "
                 "and other samsu that originate in an FTA partner, with proof "
                 "of origin (e.g. E-ATIGA Form D, ACFTA Form E, CSFTA, RCEP). "
                 "The partner list is not transcribed, so this treatment never "
                 "applies to a chosen origin automatically.",
         "source": "Singapore Customs, 'Claiming Preferential Tariff Treatment for Dutiable Imports' (customs.gov.sg/businesses/certificates-of-origin/claiming-preferential-tariff-treatment-for-dutiable-imports/, last updated 18 February 2026)"},
        {"treatment": "EXCISE", "name": "Excise duty",
         "origin_countries": [], "applies": "all_origins",
         "conditional": False, "category": "tax",
         "legal_basis": "STCCED 2022, column (7) 'Excise Duty'"},
    ]
    tout += _unknown_treatments(records, {
        "unknown_PREF": "Pref cell as printed — not a representable rate",
        "unknown_EXCISE": "Excise cell as printed — not a representable rate",
    })
    coverage = dict(SG_COVERAGE)
    coverage["as_of"] = f"{revision} · STCCED 2022 edition ({csv_path.name})"
    overlay = load_overlay("sg")
    if overlay.get("flat_taxes"):
        coverage["flat_taxes"] = overlay["flat_taxes"]
    return records, tout, coverage


# ── Malaysia ─────────────────────────────────────────────────────────────────

MY_COVERAGE = {
    "provides": [
        "Import duty (column 5 of the First Schedule) of the Customs Duties "
        "Order 2025, P.U. (A) 384, for every 10-digit line: ad valorem, "
        "specific and compound duties verbatim. A specific amount printed "
        "without a unit is per the line's unit of quantity (column 4), as "
        "paragraph 3(b) of the Order provides; amounts are never converted "
        "to percentages.",
        "Tariff-rate-quota lines (Appendix B): the out-of-quota rate as the "
        "applied rate, flagged conditional, and the in-quota rate as an "
        "informational quota row naming the agency that allocates the quota.",
        "Sales tax (SST), excise and cess 1–3 from the ezHS portal as "
        "informational tax lines.",
    ],
    "excludes": [
        "Preferential (FTA) schedules — ATIGA, ACFTA, RCEP, CPTPP and the "
        "other schemes the ezHS portal serves are not in this build.",
        "Export duty (column 6): this duty-rates surface covers imports.",
        "The flat 10% rate on dutiable goods carried by travellers for "
        "non-commercial use (paragraph 2(2) of the Order).",
        "Quota allocation and availability (operational, set by the agency "
        "named on each quota line).",
        "Excise or cess amounts printed without a unit, and other cells the "
        "build could not read, are carried verbatim and flagged — never "
        "given an assumed unit.",
    ],
    "source": "Royal Malaysian Customs — Customs Duties Order 2025, "
              "P.U. (A) 384 (gazette) + ezHS portal (SST, excise, cess)",
}
MY_REQUIRED = ("GOODS_CODE", "DISPLAY", "IS_LEAF", "UNIT", "IMPORT_RATE",
               "IMPORT_RATE_BASIS", "TRQ_IN_QUOTA", "TRQ_OUT_QUOTA",
               "TRQ_AGENCY", "SST", "EXCISE", "CESS_1", "CESS_2", "CESS_3")
MY_TAX_COLUMNS = (("SST", "SST", "Sales tax (SST)"),
                  ("EXCISE", "EXCISE", "Excise duty"),
                  ("CESS_1", "CESS_1", "Cess 1"),
                  ("CESS_2", "CESS_2", "Cess 2"),
                  ("CESS_3", "CESS_3", "Cess 3"))


def _my_parse(cell: str, unit_of_quantity: str = "",
              allow_alternatives: bool = False) -> dict:
    if cell.lower() in _NIL_WORDS:
        return {"components": [], "combine": None, "text": cell}
    if cell.upper() in ("NA", "N/A"):
        return {"error": "not_a_rate"}
    return _parse_duty_expr(cell, r"RM", "MYR", unit_of_quantity,
                            allow_alternatives=allow_alternatives)


def build_my(csv_path: Path, jur: str, revision: str):
    """MY: Customs Duties Order 2025 import duty per 10-digit leaf (the 11
    eight-digit codes are internal nodes and carry nothing), quota lines
    from Appendix B, and the ezHS portal's SST/excise/cess as taxes.

    UNIT OF A SPECIFIC DUTY: "where the rate of customs duties is specified
    as a sum of money, the customs duties shall be calculated according to
    the sum of money upon every unit specified in column (4) of the First
    Schedule" (P.U. (A) 384, para 3(b)) — so "RM 7.00" on a line whose unit
    is 'l' is RM 7.00 per l, and "5% and RM0.65" on 0807.11 (unit kg, printed
    page 104) is 5% plus RM0.65 per kg. That rule is the Customs Duties
    Order's; it does not reach the portal's excise and cess columns, so a
    unit-less amount there is flagged, not completed.

    QUOTA: "In the case of goods which are subject to tariff rate quota ...
    import duty shall be levied ... at the rate of duty as specified in
    column (5) of Appendix B" (para 2(4)). As in build_gb/build_ch, the
    out-of-quota rate is the applied MFN row (conditional, quota_note) and
    the in-quota rate an informational 'quota' row; the in-quota rate is
    never auto-selected.

    EXPORT_RATE is not emitted: no builder here models export duties."""
    rows = _read_canonical(csv_path, MY_REQUIRED, "MY")
    leaves = [r for r in rows if r["GOODS_CODE"] and r["IS_LEAF"] == "1"]
    if not leaves:
        raise SystemExit(f"ERROR: no IS_LEAF rows in {csv_path}")
    _nonleaf_rate_note("my", rows, ("IMPORT_RATE", "TRQ_IN_QUOTA",
                                    "TRQ_OUT_QUOTA"))

    records: list[dict] = []
    bases: dict[str, int] = {}
    for r in leaves:
        digits = bhc._digits_only(r["GOODS_CODE"])
        code = r["DISPLAY"] or digits
        unit = r["UNIT"]
        basis = r["IMPORT_RATE_BASIS"]
        cell = r["IMPORT_RATE"]
        bases[basis] = bases.get(basis, 0) + 1
        if basis == "schedule":
            if not cell:
                records.append(_unrepresentable(
                    jur, revision, code, digits, "MFN", cell,
                    "no_rate_in_source", "IMPORT_RATE"))
            else:
                p = _my_parse(cell, unit)
                records.append(
                    _unrepresentable(jur, revision, code, digits, "MFN", cell,
                                     p["error"], "IMPORT_RATE")
                    if "error" in p
                    else _expr_record(jur, revision, code, digits, "MFN",
                                      cell, p))
        elif basis == "trq_appendix_b":
            in_q, out_q, agency = (r["TRQ_IN_QUOTA"], r["TRQ_OUT_QUOTA"],
                                   r["TRQ_AGENCY"])
            p_out = _my_parse(out_q, unit) if out_q else {"error":
                                                          "no_rate_in_source"}
            if "error" in p_out:
                records.append(_unrepresentable(
                    jur, revision, code, digits, "MFN", out_q,
                    f"trq_out_quota_{p_out['error']}", "TRQ_OUT_QUOTA"))
            else:
                rec = _expr_record(jur, revision, code, digits, "MFN", out_q,
                                   p_out, conditional=True)
                rec["rate_basis"] = "trq_appendix_b"
                rec["quota_note"] = (
                    "Tariff-rate quota line (Appendix B): out-of-quota rate "
                    f"shown; in-quota rate {in_q or 'not printed'}"
                    + (f", quota set by {agency}" if agency else ""))
                records.append(rec)
            if in_q:
                p_in = _my_parse(in_q, unit)
                if "error" in p_in:
                    records.append(_unrepresentable(
                        jur, revision, code, digits, "quota_in", in_q,
                        p_in["error"], "TRQ_IN_QUOTA"))
                else:
                    rec = _expr_record(jur, revision, code, digits,
                                       "quota_in", in_q, p_in,
                                       informational=True, category="quota",
                                       conditional=True)
                    if agency:
                        rec["conditions"] = [f"Quota set by {agency}"]
                    records.append(rec)
        elif basis == "unresolved":
            records.append(_unrepresentable(
                jur, revision, code, digits, "MFN", cell, "unresolved",
                "IMPORT_RATE",
                note="The parser could not resolve this line's import duty "
                     "from the gazette; no rate is asserted."))
        else:
            records.append(_unrepresentable(
                jur, revision, code, digits, "MFN", cell,
                f"unknown_basis:{basis or 'blank'}", "IMPORT_RATE_BASIS"))

        for col, treatment, _name in MY_TAX_COLUMNS:
            val = r[col]
            if not val:
                continue
            p = _my_parse(val, allow_alternatives=True)
            if "error" in p:
                records.append(_unrepresentable(
                    jur, revision, code, digits, treatment, val, p["error"],
                    col))
            else:
                records.append(_expr_record(
                    jur, revision, code, digits, treatment, val, p,
                    informational=True, category="tax",
                    conditional=p["combine"] == "alternatives"))

    print(f"[my] {len(leaves):,} leaves by import-rate basis: {bases}")
    _flag_report("my", records)
    _static_mfn_gate("MY", [bhc._digits_only(r["GOODS_CODE"]) for r in leaves],
                     records, set())

    tout = [
        {"treatment": "MFN",
         "name": "Import duty (Customs Duties Order 2025, First Schedule "
                 "column 5)",
         "origin_countries": [], "applies": "all_origins",
         "conditional": False,
         "legal_basis": "Customs Duties Order 2025, P.U. (A) 384, paras 2(1) "
                        "and 3; quota lines para 2(4) and Appendix B"},
        {"treatment": "quota_in",
         "name": "Tariff-rate quota — in-quota rate (Appendix B)",
         "origin_countries": [], "applies": None, "conditional": True,
         "category": "quota",
         "legal_basis": "Customs Duties Order 2025, para 2(4); First "
                        "Schedule, Appendix B column (5)",
         "note": "Applies only to imports within the quota allocated by the "
                 "agency named on the line; never auto-selected."},
    ]
    for col, treatment, name in MY_TAX_COLUMNS:
        tout.append({
            "treatment": treatment,
            "name": name + (" (ezHS portal column; the portal does not name "
                            "the cess)" if col.startswith("CESS") else ""),
            "origin_countries": [], "applies": "all_origins",
            "conditional": False, "category": "tax",
            "legal_basis": "Royal Malaysian Customs ezHS portal, PDK 2025 "
                           f"'{col.replace('_', ' ')}' column",
            **({"note": "Rates separated by '/' are alternatives as printed; "
                        "which applies depends on the goods' conditions."}
               if col == "SST" else {})})
    tout += _unknown_treatments(records, {})
    coverage = dict(MY_COVERAGE)
    coverage["as_of"] = (f"{revision} · Customs Duties Order 2025, in force "
                         f"2025-11-01 ({csv_path.name})")
    overlay = load_overlay("my")
    if overlay.get("flat_taxes"):
        coverage["flat_taxes"] = overlay["flat_taxes"]
    return records, tout, coverage


# ── Vietnam ──────────────────────────────────────────────────────────────────

VN_COVERAGE = {
    "provides": [
        "MFN import duty (thuế nhập khẩu ưu đãi) for every 8-digit line, "
        "including Vietnam's national Chapter 98, each with the Decree that "
        "enacts it and that Decree's effective date.",
        "The ordinary rate (thuế nhập khẩu thông thường), which applies "
        "absent MFN or FTA eligibility, as an informational general rate.",
        "Tariff-rate-quota lines: the out-of-quota rate (ngoài hạn ngạch) as "
        "the applied rate, flagged conditional, and the in-quota rate as an "
        "informational quota row.",
        "VAT band(s) as an informational tax line.",
        "MFN amendments enacted after the workbook's date, from the signed "
        "Decrees and Resolutions (config/duty_overlays/vn.json): while a "
        "temporary rate is in force on the build date it is the MFN rate "
        "served, dated (valid_from / valid_until), and the base rate that "
        "returns after it follows as an informational scheduled rate. In "
        "2026 that is 0% on 18 petrol, diesel, jet-fuel, LPG and "
        "petrochemical-feedstock lines under Decree 72/2026/NĐ-CP and "
        "Resolution 25/2026/NQ-CP, extended to 31 December 2026 by "
        "Resolution 43/2026/NQ-CP.",
    ],
    "excludes": [
        "FTA preferential schedules (ATIGA, ACFTA, CPTPP, RCEP, EVFTA, "
        "UKVFTA and the rest sit in other sheets of the same workbook and "
        "are not in this build).",
        "Chapter 87 lines whose MFN cell refers to the guidance in Chapter "
        "98 instead of stating a rate, and the ordinary rates stated as "
        "'150% of the MFN duty' on those lines: carried verbatim and "
        "flagged, never shown as a rate.",
        "Temporary rates outside their window on the build date: the base "
        "rate is served and the window is recorded on the line. Rates "
        "follow the build date, so a temporary rate stays served until the "
        "next build after it ends.",
        "The ordinary rate is shown as printed in the workbook; the "
        "temporary MFN reductions are not applied to it.",
        "Amendments enacted after the overlay's checked-through date.",
        "Export duty, environmental protection tax and special consumption "
        "tax.",
        "Provenance: the workbook is a compilation by the Quang Ninh Customs "
        "Sub-Department redistributed by a third-party law library, not the "
        "issuing instrument; the citable authority is the Decree named on "
        "each rate.",
    ],
    "source": "Vietnam Import-Export Tariff workbook (BT2026 sheet), "
              "compiled by the Quang Ninh Customs Sub-Department",
}
VN_REQUIRED = ("GOODS_CODE", "DISPLAY", "IS_LEAF", "MFN_RATE",
               "ORDINARY_RATE", "VAT", "MFN_DECREE", "MFN_EFFECTIVE")

_VN_NUM = r"(\d+(?:\.\d+)?)"
_VN_PCT = re.compile(_VN_NUM)
# "30 (NHN: 80)": 30% in quota, 80% outside it (NHN = ngoài hạn ngạch).
_VN_TRQ = re.compile(_VN_NUM + r"\s*\(\s*NHN\s*:\s*" + _VN_NUM + r"\s*\)")
# "7 (0% từ 09/3-30/4 theo NĐ72)": 7%, with 0% from 9/3 to 30/4 under
# Decree 72. The window prints no year.
_VN_WINDOW = re.compile(_VN_NUM + r"\s*\(\s*" + _VN_NUM + r"\s*%\s*từ\s*"
                        r"(\d{1,2})/(\d{1,2})\s*-\s*(\d{1,2})/(\d{1,2})\s*"
                        r"theo\s+([^)]+?)\s*\)")
# "Theo hướng dẫn tại khoản 1.1 Chương 98" — "as guided in clause 1.1 of
# Chapter 98": a pointer to Chapter 98's provisions, not a rate.
_VN_XREF = re.compile(r"Theo hướng dẫn tại\s+(.+?)\s+Chương\s+98")
# "150% thuế MFN": 150% OF the MFN duty — a multiple, not a rate.
_VN_RELATIVE = re.compile(_VN_NUM + r"\s*%\s*thuế\s+MFN")
_VN_GLOSS = {"khoản": "clause", "điểm": "point", "và": "and"}


def _vn_date(ddmmyyyy: str) -> str:
    try:
        return _dt.datetime.strptime(ddmmyyyy, "%d/%m/%Y").date().isoformat()
    except ValueError:
        return ""


def _vn_pct_text(num: str) -> str:
    return f"{num}%"


def _vn_amendments(overlay: dict) -> dict[str, dict]:
    """config/duty_overlays/vn.json `rate_amendments` -> {digits: amendment}.
    Malformed or overlapping entries stop the build: a rate that changes law
    must not be half-applied."""
    by_digits: dict[str, dict] = {}
    for a in overlay.get("rate_amendments", []):
        for key in ("id", "rate_pct", "valid_from", "valid_until",
                    "regulation_id", "base_rate_pct", "instruments"):
            if key not in a:
                raise SystemExit(f"ERROR: vn overlay amendment "
                                 f"{a.get('id', '?')!r} lacks {key!r}")
        start = _dt.date.fromisoformat(a["valid_from"])
        end = _dt.date.fromisoformat(a["valid_until"])
        if end < start:
            raise SystemExit(f"ERROR: vn overlay amendment {a['id']!r} ends "
                             f"before it starts")
        if not a["instruments"]:
            raise SystemExit(f"ERROR: vn overlay amendment {a['id']!r} cites "
                             f"no instrument")
        for digits in a["base_rate_pct"]:
            if digits in by_digits:
                raise SystemExit(f"ERROR: {digits} is amended by both "
                                 f"{by_digits[digits]['id']!r} and "
                                 f"{a['id']!r} in the vn overlay")
            by_digits[digits] = {**a, "_start": start, "_end": end}
    return by_digits


def _vn_extension_text(a: dict) -> str:
    """'72/2026/NĐ-CP, extended to 2026-12-31 by 43/2026/NQ-CP' — the
    enacting instrument and the one that set the current end date."""
    last = a["instruments"][-1]["number"]
    if last == a["regulation_id"]:
        return a["regulation_id"]
    return (f"{a['regulation_id']}, extended to {a['valid_until']} by "
            f"{last}")


def build_vn(csv_path: Path, jur: str, revision: str,
             snapshot_date: _dt.date | None = None,
             overlay: dict | None = None):
    """VN: MFN_RATE (the MFN duty, bare numbers meaning percent) per 8-digit
    leaf, ORDINARY_RATE as TW's general column (informational), VAT as a tax.
    Chapter 98 lines are ordinary leaves.

    Patterns in the two rate columns, each handled explicitly:
      N                         -> N%
      N (NHN: M)                -> TRQ: MFN row = M% out-of-quota
                                   (conditional), quota row = N% in-quota
      N (T% từ d/m-d/m theo X)  -> temporary window: the BASE N% is served;
                                   the window (year taken from the
                                   revision's leading year — the workbook
                                   prints none) is recorded on the record,
                                   and only while it is open or upcoming at
                                   `snapshot_date` (default today) is it
                                   also an informational temporary_rate row
      Theo hướng dẫn tại … Chương 98  -> cross-reference, flagged
      N% thuế MFN               -> a multiple of the MFN duty, flagged
      blank on a leaf           -> flagged (no_rate_in_source)
      anything else             -> flagged (unrecognised)

    Amendments enacted after the workbook's date come from the overlay
    (config/duty_overlays/vn.json `rate_amendments`) and supersede whatever
    the MFN cell prints, printed window included. Unlike a printed window --
    which states no year -- each is dated and cited, so while it is in force
    at `snapshot_date` its rate IS the MFN rate served (valid_from /
    valid_until on the row), and the base rate it displaces follows as an
    informational `MFN_scheduled` row dated from the day after it ends.
    Outside its window the base rate is served. The workbook must still
    print the base rate the overlay expects for every amended line, or the
    build stops: either the workbook has caught up or the overlay is wrong,
    and either way it needs reading, not guessing."""
    rows = _read_canonical(csv_path, VN_REQUIRED, "VN")
    leaves = [r for r in rows if r["GOODS_CODE"] and r["IS_LEAF"] == "1"]
    if not leaves:
        raise SystemExit(f"ERROR: no IS_LEAF rows in {csv_path}")
    _nonleaf_rate_note("vn", rows, ("MFN_RATE", "ORDINARY_RATE", "VAT"))
    snapshot = snapshot_date or _dt.date.today()
    ym = re.match(r"(\d{4})", revision)
    window_year = int(ym.group(1)) if ym else None
    if overlay is None:
        overlay = load_overlay("vn")
    amendments = _vn_amendments(overlay)
    leaf_digits = {bhc._digits_only(r["GOODS_CODE"]) for r in leaves}
    missing = sorted(set(amendments) - leaf_digits)
    if missing:
        raise SystemExit(f"ERROR: the vn overlay amends {missing}, which are "
                         f"not leaves of {csv_path.name} -- review "
                         f"config/duty_overlays/vn.json")

    records: list[dict] = []
    known_non_rate: set[str] = set()
    windows = {"expired": 0, "open": 0, "upcoming": 0, "undated": 0}
    amended = {"in_force": 0, "ended": 0, "not_yet": 0}

    def amend(r, code, digits, cell) -> list[dict]:
        """An MFN cell the overlay amends -> its records (see docstring)."""
        a = amendments[digits]
        m = _VN_WINDOW.fullmatch(cell) or _VN_PCT.fullmatch(cell)
        base_rate = m.group(1) if m else None
        if base_rate is None or float(base_rate) != float(
                a["base_rate_pct"][digits]):
            raise SystemExit(
                f"ERROR: {code}: the vn overlay amendment {a['id']!r} expects "
                f"a base MFN rate of {a['base_rate_pct'][digits]}%, but the "
                f"workbook prints {cell!r} -- review "
                f"config/duty_overlays/vn.json")
        basis = _vn_extension_text(a)
        rate_text = _vn_pct_text(f"{a['rate_pct']:g}")
        if a["_start"] <= snapshot <= a["_end"]:
            amended["in_force"] += 1
            rec = _record(jur, revision, code, digits, "MFN", rate_text)
            rec.update({
                "valid_from": a["valid_from"], "valid_until": a["valid_until"],
                "regulation_id": a["regulation_id"],
                "regulation_effective": a["valid_from"],
                "temporary_basis": basis, "amendment_id": a["id"],
                "source_text": cell,
                "note": (f"Temporary {rate_text} under {basis} (in force "
                         f"{a['valid_from']} to {a['valid_until']}); base rate "
                         f"{base_rate}% ({r['MFN_DECREE'] or 'Decree as printed'}) "
                         f"after that. {a.get('after_expiry', '')}").strip()})
            nxt = _record(jur, revision, code, digits, "MFN_scheduled",
                          _vn_pct_text(base_rate), informational=True,
                          category="scheduled_rate")
            nxt["valid_from"] = (a["_end"] + _dt.timedelta(days=1)).isoformat()
            nxt["note"] = (f"The base MFN rate, which applies again when the "
                           f"temporary rate under {basis} ends")
            return [rec, provenance(nxt, r)]
        status = "ended" if snapshot > a["_end"] else "not_yet"
        amended[status] += 1
        rec = provenance(_record(jur, revision, code, digits, "MFN",
                                 _vn_pct_text(base_rate)), r)
        rec["source_text"] = cell
        rec["amendment_id"] = a["id"]
        rec["note"] = (f"Temporary {rate_text} under {basis} "
                       f"({a['valid_from']} to {a['valid_until']}) "
                       f"{'ended' if status == 'ended' else 'not yet in force'}"
                       f" at {snapshot.isoformat()} -- base rate "
                       f"{base_rate}% served")
        return [rec]

    def provenance(rec, r):
        if r["MFN_DECREE"]:
            rec["regulation_id"] = r["MFN_DECREE"]
        eff = _vn_date(r["MFN_EFFECTIVE"])
        if eff:
            rec["regulation_effective"] = eff
        return rec

    def emit(r, code, digits, column, cell):
        """One rate cell -> records. MFN rows are duties; ordinary rows are
        informational general_rate rows like TW's Column III."""
        is_mfn = column == "MFN_RATE"
        if is_mfn and digits in amendments:
            return amend(r, code, digits, cell)
        base = "MFN" if is_mfn else "general_non_mfn"
        kw = ({} if is_mfn else
              {"informational": True, "category": "general_rate"})
        out: list[dict] = []

        def rate(treatment, text, **extra):
            rec = _record(jur, revision, code, digits, treatment, text,
                          **{**kw, **extra})
            return provenance(rec, r) if is_mfn else rec

        if not cell:
            out.append(_unrepresentable(jur, revision, code, digits, base,
                                        cell, "no_rate_in_source", column))
        elif _VN_PCT.fullmatch(cell):
            out.append(rate(base, _vn_pct_text(cell)))
        elif (m := _VN_TRQ.fullmatch(cell)):
            in_q, out_q = m.group(1), m.group(2)
            rec = rate(base, _vn_pct_text(out_q), conditional=True)
            rec["quota_note"] = (f"Tariff-rate quota line: out-of-quota "
                                 f"(ngoài hạn ngạch) rate shown; in-quota "
                                 f"rate {in_q}%")
            rec["source_text"] = cell
            out.append(rec)
            q = _record(jur, revision, code, digits,
                        "quota_in" if is_mfn else f"quota_in_{base}",
                        _vn_pct_text(in_q), informational=True,
                        category="quota", conditional=True)
            q["source_text"] = cell
            out.append(provenance(q, r) if is_mfn else q)
        elif (m := _VN_WINDOW.fullmatch(cell)):
            base_rate, temp, d1, m1, d2, m2, decree = m.groups()
            rec = rate(base, _vn_pct_text(base_rate))
            rec["source_text"] = cell
            start = end = None
            if window_year:
                try:
                    start = _dt.date(window_year, int(m1), int(d1))
                    end = _dt.date(window_year, int(m2), int(d2))
                except ValueError:
                    start = end = None
            if start is None or end < start:
                status = "undated"
                span = f"{d1}/{m1}–{d2}/{m2} (year not determinable)"
            else:
                status = ("expired" if end < snapshot else
                          "open" if start <= snapshot else "upcoming")
                span = f"{start.isoformat()} to {end.isoformat()}"
            windows[status] += 1
            rec["note"] = (f"Temporary {temp}% from {span} under {decree} "
                           f"(as printed: \"{cell}\"); window {status} at "
                           f"{snapshot.isoformat()} — base rate {base_rate}% "
                           f"served")
            out.append(rec)
            if status in ("open", "upcoming", "undated"):
                t = _record(jur, revision, code, digits,
                            f"temporary_rate_{base}" if not is_mfn
                            else "temporary_rate", _vn_pct_text(temp),
                            informational=True, category="temporary_rate",
                            conditional=True)
                t["source_text"] = cell
                t["note"] = rec["note"]
                if end and status != "undated":
                    t["valid_until"] = end.isoformat()
                out.append(provenance(t, r) if is_mfn else t)
        elif (m := _VN_XREF.fullmatch(cell)):
            if is_mfn:
                known_non_rate.add(digits)
            out.append(_unrepresentable(
                jur, revision, code, digits, base, cell, "cross_reference",
                column, note=("Not a rate: 'as guided in "
                              + " ".join(_VN_GLOSS.get(w, w)
                                         for w in m.group(1).split())
                              + " of Chapter 98' — the duty is set by "
                                "Chapter 98's provisions")))
        elif (m := _VN_RELATIVE.fullmatch(cell)):
            out.append(_unrepresentable(
                jur, revision, code, digits, base, cell, "relative_to_mfn",
                column, note=f"Not a rate: {m.group(1)}% OF the MFN duty "
                             f"(thuế MFN)"))
        else:
            out.append(_unrepresentable(jur, revision, code, digits, base,
                                        cell, "unrecognised", column))
        if is_mfn:
            for rec in out:
                if rec.get("category") == "unknown":
                    provenance(rec, r)
        return out

    for r in leaves:
        digits = bhc._digits_only(r["GOODS_CODE"])
        code = r["DISPLAY"] or digits
        records.extend(emit(r, code, digits, "MFN_RATE", r["MFN_RATE"]))
        records.extend(emit(r, code, digits, "ORDINARY_RATE",
                            r["ORDINARY_RATE"]))
        vat = r["VAT"]
        if vat:
            bands = [b.strip() for b in vat.split("/")]
            if all(b == "*" or _VN_PCT.fullmatch(b) for b in bands):
                text = "/".join(b if b == "*" else f"{b}%" for b in bands)
                rec = _record(jur, revision, code, digits, "VAT", text,
                              informational=True, category="tax",
                              conditional=len(bands) > 1)
                if text != vat:
                    rec["source_text"] = vat
                records.append(rec)
            else:
                records.append(_unrepresentable(
                    jur, revision, code, digits, "VAT", vat, "unrecognised",
                    "VAT"))

    print(f"[vn] temporary windows: {windows} (snapshot "
          f"{snapshot.isoformat()}; window year "
          f"{window_year or 'unknown'} from revision {revision!r})")
    print(f"[vn] overlay amendments: {amended} on {len(amendments)} lines "
          f"(checked through {overlay.get('checked_through', '?')})")
    _flag_report("vn", records)
    _static_mfn_gate("VN", [bhc._digits_only(r["GOODS_CODE"]) for r in leaves],
                     records, known_non_rate)

    def _decree_key(d: str):
        parts = re.findall(r"\d+", d)          # "26/2023/NĐ-CP" -> year, number
        return (int(parts[1]), int(parts[0])) if len(parts) >= 2 else (0, 0)

    decrees = sorted({r["MFN_DECREE"] for r in leaves if r["MFN_DECREE"]},
                     key=_decree_key)
    in_force = {a["id"]: a for a in amendments.values()
                if a["_start"] <= snapshot <= a["_end"]}
    tout = [
        {"treatment": "MFN",
         "name": "MFN import duty (thuế nhập khẩu ưu đãi)",
         "origin_countries": [], "applies": "all_origins",
         "conditional": False,
         "legal_basis": "Decree(s) " + ", ".join(decrees)
                        + " — each rate carries its own Decree "
                          "(regulation_id) and effective date"
                        + "".join(f"; temporarily {a['rate_pct']:g}% on "
                                  f"{len(a['base_rate_pct'])} lines under "
                                  f"{_vn_extension_text(a)}"
                                  for a in in_force.values())},
        {"treatment": "MFN_scheduled",
         "name": "MFN rate that applies again when a temporary rate ends",
         "origin_countries": [], "applies": "all_origins",
         "conditional": False, "category": "scheduled_rate",
         "legal_basis": "The Decree named on the line (regulation_id)",
         "note": "Informational: the base rate a temporary MFN rate "
                 "displaces, dated from the day after the temporary rate "
                 "ends. Never the rate in force."},
        {"treatment": "general_non_mfn",
         "name": "Ordinary rate (thuế nhập khẩu thông thường) — applies "
                 "absent MFN or FTA eligibility",
         "origin_countries": [], "applies": None, "conditional": True,
         "legal_basis": "Vietnam Import-Export Tariff, ordinary-rate column"},
        {"treatment": "quota_in",
         "name": "Tariff-rate quota — in-quota MFN rate",
         "origin_countries": [], "applies": None, "conditional": True,
         "category": "quota",
         "legal_basis": "Vietnam Import-Export Tariff, MFN column (in-quota "
                        "figure; 'NHN' = out-of-quota)",
         "note": "Applies only to imports within an allocated quota; never "
                 "auto-selected."},
        {"treatment": "quota_in_general_non_mfn",
         "name": "Tariff-rate quota — in-quota ordinary rate",
         "origin_countries": [], "applies": None, "conditional": True,
         "category": "quota",
         "legal_basis": "Vietnam Import-Export Tariff, ordinary-rate column"},
        {"treatment": "VAT", "name": "VAT on import (thuế GTGT)",
         "origin_countries": [], "applies": "all_origins",
         "conditional": False, "category": "tax",
         "legal_basis": "Vietnam Import-Export Tariff, VAT column",
         "note": "Bands separated by '/' are alternatives as printed; "
                 "which applies depends on the goods. '*' is carried as "
                 "printed (read elsewhere in this repo as 'not subject to "
                 "VAT'; not re-verified against the workbook legend)."},
    ]
    emitted = {r["treatment"] for r in records}
    for t in ("temporary_rate", "temporary_rate_general_non_mfn"):
        if t in emitted:
            tout.append({"treatment": t,
                         "name": "Temporary reduced rate (open window)",
                         "origin_countries": [], "applies": None,
                         "conditional": True, "category": "temporary_rate",
                         "legal_basis": "Decree cited in the cell"})
    tout = [t for t in tout if t["treatment"] in emitted
            or t["treatment"] in ("MFN", "general_non_mfn", "VAT")]
    tout += _unknown_treatments(records, {
        "unknown_MFN": "MFN cell as printed — not a representable rate "
                       "(e.g. a Chapter 98 cross-reference)",
        "unknown_general_non_mfn": "Ordinary-rate cell as printed — not a "
                                   "representable rate (e.g. '150% of the "
                                   "MFN duty')",
    })
    coverage = dict(VN_COVERAGE)
    meta_path = csv_path.with_name(csv_path.name + ".meta.json")
    meta = (json.loads(meta_path.read_text(encoding="utf-8"))
            if meta_path.is_file() else {})
    edition = meta.get("edition_label") or meta.get("effective_date_label")
    coverage["as_of"] = (
        f"{revision} · rates in force on {snapshot.isoformat()}: "
        f"{edition or 'the workbook'} with the official MFN amendments "
        f"checked through "
        f"{overlay.get('checked_through', 'an unrecorded date')} applied "
        f"({csv_path.name})")
    if overlay.get("flat_taxes"):
        coverage["flat_taxes"] = overlay["flat_taxes"]
    return records, tout, coverage


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("source", type=Path,
                   help="canonical CSV (cbsa/dga/sg/my/vn) or Duties Import "
                        "xlsx (taric)")
    p.add_argument("--source-format",
                   choices=("cbsa", "taric", "dga", "uk", "ch", "kr", "tw",
                            "sg", "my", "vn"), required=True)
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
    p.add_argument("--base-data", type=Path,
                   help="ch: TariffBaseMasterData XML")
    p.add_argument("--created", default="",
                   help="ch: master-data creation timestamp for as_of")
    p.add_argument("--classes", type=Path,
                   help="kr: config/kr_rate_classes.json (rate-class "
                        "dictionary + precedence)")
    p.add_argument("--rates-date", default="",
                   help="kr: the rates file's dated filename suffix for the "
                        "coverage as-of line")
    p.add_argument("--declarable", type=Path,
                   help="uk: declarable.json from the acquire step (sid "
                        "universe + reconciliation samples)")
    p.add_argument("--snapshot-date", default=None,
                   help="taric: the extract's snapshot date (YYYY-MM-DD); "
                        "measures whose end date is before this are dropped. "
                        "vn (optional, default today): the date temporary "
                        "rate windows are judged open/expired against")
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
    elif args.source_format == "uk":
        for flag, val in (("--nomenclature", args.nomenclature),
                          ("--snapshot-date", args.snapshot_date),
                          ("--geo-areas", args.geo_areas),
                          ("--declarable", args.declarable)):
            if not val:
                sys.exit(f"ERROR: {flag} is required for uk")
        records, treatments, coverage = build_gb(
            args.source, args.geo_areas, jur, args.revision,
            nomenclature_csv=args.nomenclature,
            snapshot_date=_dt.date.fromisoformat(args.snapshot_date),
            declarable_json=args.declarable)
    elif args.source_format == "ch":
        for flag, val in (("--nomenclature", args.nomenclature),
                          ("--snapshot-date", args.snapshot_date),
                          ("--geo-areas", args.geo_areas)):
            if not val:
                sys.exit(f"ERROR: {flag} is required for ch")
        records, treatments, coverage = build_ch(
            args.source, args.geo_areas, jur, args.revision,
            nomenclature_csv=args.nomenclature,
            snapshot_date=_dt.date.fromisoformat(args.snapshot_date),
            base_xml=args.base_data, created=args.created)
    elif args.source_format == "tw":
        if not args.nomenclature:
            sys.exit("ERROR: --nomenclature is required for tw")
        records, treatments, coverage = build_tw(
            args.source, jur, args.revision,
            nomenclature_csv=args.nomenclature)
    elif args.source_format == "kr":
        for flag, val in (("--nomenclature", args.nomenclature),
                          ("--snapshot-date", args.snapshot_date),
                          ("--classes", args.classes)):
            if not val:
                sys.exit(f"ERROR: {flag} is required for kr")
        records, treatments, coverage = build_kr(
            args.source, jur, args.revision,
            nomenclature_csv=args.nomenclature,
            snapshot_date=_dt.date.fromisoformat(args.snapshot_date),
            classes_json=args.classes, rates_date=args.rates_date)
    elif args.source_format == "sg":
        records, treatments, coverage = build_sg(args.source, jur, args.revision)
    elif args.source_format == "my":
        records, treatments, coverage = build_my(args.source, jur, args.revision)
    elif args.source_format == "vn":
        records, treatments, coverage = build_vn(
            args.source, jur, args.revision,
            snapshot_date=(_dt.date.fromisoformat(args.snapshot_date)
                           if args.snapshot_date else None))
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
        "inherit": ("ancestor-walk" if args.source_format in ("taric", "uk") else "exact"),
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
