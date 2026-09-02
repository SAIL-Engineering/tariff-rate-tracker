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
    p.add_argument("--source-format", choices=("cbsa", "taric", "dga", "uk", "ch", "kr"), required=True)
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
