#!/usr/bin/env python3
"""build_explorer_dataset.py — emit the SPA HTS Explorer dataset for a jurisdiction.

The US Explorer reads the USITC raw JSON (shipped as hts_<year>_revision_<n>
.json). Other jurisdictions have no such publication, so this tool emits the
same row shape the SPA's htsAdapter.normalizeRawEntry() consumes —
  { htsno, indent, description, superior, units, general, special, other, footnotes }
— from the SAME loaders build_hts_corpus.py uses, so the Explorer tree and the
classification corpus can never disagree about structure.

Rate columns (Explorer duty display; the duty-rates JSON from
build_duty_rates.py is the richer surface):
  CA  general = MFN (raw, uninherited — as the printed book shows it),
      special = compact preferential summary, other = General Tariff
  EU  empty — EU duties are measures (per-origin), not schedule columns
  DO  general = Grav. (MFN %); ITBIS/Selectivo are taxes, not tariffs -> duty JSON
  SG  general = CUSTOMS DUTY (FULL), special = CUSTOMS DUTY (PREF),
      other   = EXCISE DUTY, prefixed "Excise: ".

      Singapore prints all three in the schedule, and almost every line is
      blank in all three because the duty is genuinely nil, not because the
      source is silent: of 14,460 codes, 8 carry a full customs duty (beer and
      samsu), 16 a preferential one, and 597 an excise duty (chapters 21, 22,
      24, 27, 33, 38 and 87). The "other" column means US Column 2 elsewhere,
      so the excise value is prefixed rather than dropped in bare - it must
      never be read as a customs rate.
  MY  general = import duty, special = the tariff-rate-quota detail where one
      applies, other = sales tax, excise and export duty, each labelled.

      Malaysia prints real rates: of 11,441 lines, 11,414 carry an import duty
      and 27 are quota-controlled with the figures in Appendix B of the
      gazette. A quota line's import duty is deliberately EMPTY with
      IMPORT_RATE_BASIS=trq_appendix_b, because the portal shows it blank and
      reading that as zero would publish quota-controlled meat as duty-free;
      the in-quota and out-of-quota rates go in `special` instead.

  build_explorer_dataset.py <csv> --source-format cbsa --jurisdiction CA \
      --out ca_2026_revision_2.json
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_hts_corpus as bhc  # noqa: E402

# CA preferential columns worth naming in the compact summary (full set lives
# in build_duty_rates.py).
CA_SPECIAL_COLS = ("UST", "MXT", "CEUT", "CPTPT", "UKT", "CPUKT", "CCCT", "LDCT", "GPT", "KRT", "JT")


def _ca_rates(csv_path: Path) -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {}
    with csv_path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            digits = bhc._digits_only(r.get("TARIFF") or "")
            if digits and digits not in out:
                out[digits] = r
    return out


def _do_rates(csv_path: Path) -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {}
    with csv_path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            clean = {(k or "").strip(): (v or "").strip() for k, v in r.items()}
            digits = bhc._digits_only(clean.get("Código") or "")
            if digits and "[" not in (clean.get("Código") or "") and digits not in out:
                out[digits] = clean
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("csv_path", type=Path)
    p.add_argument("--source-format",
                   choices=("cbsa", "taric", "dga", "ch", "kr", "tw", "sg", "my"),
                   required=True)
    p.add_argument("--jurisdiction", required=True)
    p.add_argument("--lang", default="en")
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()

    bhc.CORPUS_LANG = args.lang if args.lang in bhc._BASKET_RES else "en"
    loaders = {"cbsa": bhc.load_rows_cbsa, "taric": bhc.load_rows_taric,
               "dga": bhc.load_rows_dga, "ch": bhc.load_rows_ch, "kr": bhc.load_rows_kr,
               "tw": bhc.load_rows_tw, "sg": bhc.load_rows_sg,
               "my": bhc.load_rows_my}
    rows, stats = loaders[args.source_format](args.csv_path)

    rates: dict[str, dict[str, str]] = {}
    if args.source_format in ("sg", "my"):
        # The duty columns are already on the parsed row, keyed by code.
        with args.csv_path.open(newline="", encoding="utf-8-sig") as fh:
            for row in csv.DictReader(fh):
                digits = (row.get("GOODS_CODE") or "").strip()
                if digits:
                    rates[digits] = row
    if args.source_format == "cbsa":
        rates = _ca_rates(args.csv_path)
    elif args.source_format == "dga":
        rates = _do_rates(args.csv_path)

    entries = []
    for row in rows:
        code = (row.get("HTS Number") or "").strip()
        digits = row.get("_digits") or bhc._digits_only(code)
        desc = row.get("Description") or ""
        general = special = other = ""
        units = bhc._parse_units(row.get("Unit of Quantity", ""))
        if args.source_format == "cbsa" and digits in rates:
            r = rates[digits]
            general = (r.get("MFN") or "").strip()
            other = (r.get("General Tariff") or "").strip()
            parts = [f"{c}: {r[c].strip()}" for c in CA_SPECIAL_COLS
                     if (r.get(c) or "").strip()]
            special = "; ".join(parts)
        elif args.source_format == "sg" and digits in rates:
            r = rates[digits]
            general = (r.get("DUTY_FULL") or "").strip()
            special = (r.get("DUTY_PREF") or "").strip()
            excise = (r.get("EXCISE") or "").strip()
            other = f"Excise: {excise}" if excise else ""
        elif args.source_format == "my" and digits in rates:
            r = rates[digits]
            general = (r.get("IMPORT_RATE") or "").strip()
            in_q = (r.get("TRQ_IN_QUOTA") or "").strip()
            out_q = (r.get("TRQ_OUT_QUOTA") or "").strip()
            if in_q or out_q:
                agency = (r.get("TRQ_AGENCY") or "").strip()
                special = (f"TRQ in-quota: {in_q or '-'}; out-of-quota: "
                           f"{out_q or '-'}" + (f" ({agency})" if agency else ""))
            parts = []
            for label, key in (("SST", "SST"), ("Excise", "EXCISE"),
                               ("Export", "EXPORT_RATE")):
                value = (r.get(key) or "").strip()
                if value:
                    parts.append(f"{label}: {value}")
            for i in (1, 2, 3):
                value = (r.get(f"CESS_{i}") or "").strip()
                if value:
                    parts.append(f"Cess {i}: {value}")
            other = "; ".join(parts)
        elif args.source_format == "dga" and digits in rates:
            grav = rates[digits].get("Grav.") or rates[digits].get("Grav") or ""
            general = f"{grav}%" if grav else ""
        entries.append({
            "htsno": code,
            "indent": str(row.get("_indent", 0)),
            "description": desc,
            "superior": None if code else "true",
            "units": units,
            "general": general,
            "special": special,
            "other": other,
            "footnotes": [],
        })

    if not entries:
        print("ERROR: no entries produced", file=sys.stderr)
        return 2
    coded = sum(1 for e in entries if e["htsno"])
    if coded != stats.coded_row_count:
        print(f"ERROR: emitted {coded} coded entries but loader counted "
              f"{stats.coded_row_count}", file=sys.stderr)
        return 5

    args.out.write_text(json.dumps(entries, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {len(entries):,} Explorer rows ({coded:,} coded) -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
