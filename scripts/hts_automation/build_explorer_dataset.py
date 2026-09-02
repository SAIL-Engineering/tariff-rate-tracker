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
    p.add_argument("--source-format", choices=("cbsa", "taric", "dga", "ch", "kr"), required=True)
    p.add_argument("--jurisdiction", required=True)
    p.add_argument("--lang", default="en")
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()

    bhc.CORPUS_LANG = args.lang if args.lang in bhc._BASKET_RES else "en"
    loaders = {"cbsa": bhc.load_rows_cbsa, "taric": bhc.load_rows_taric,
               "dga": bhc.load_rows_dga, "ch": bhc.load_rows_ch, "kr": bhc.load_rows_kr}
    rows, stats = loaders[args.source_format](args.csv_path)

    rates: dict[str, dict[str, str]] = {}
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
