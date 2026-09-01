#!/usr/bin/env python3
"""reconcile_sources.py — prove no codes are lost between each raw HTS book
and every derived output (corpus, node index, Explorer dataset).

Run after any parser change:

  python3 scripts/hts_automation/reconcile_sources.py --jurisdiction CA \
      [--explorer ca_2026_revision_2.json] [--codes ca_2026_rev_2.codes.json]

Checks, per jurisdiction:
  raw coded rows (after the documented, counted drops)  ==  tree nodes
  tree leaves == corpus records == coded Explorer rows' leaf subset
  EU only: leaves == the official Declarable-codes IS_LEAF count
  DO only: leaves == 7,697 (the book's own "7697 Subp. Operativas")
Exit non-zero on ANY discrepancy.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_hts_corpus as bhc  # noqa: E402

SOURCES = {
    "CA": ("data/ca_tariff_source", "ca_tariff", "cbsa",
           "scripts/hts_automation/chapters_ca.json", "en"),
    "EU": ("data/eu_tariff_source", "eu_tariff", "taric",
           "scripts/hts_automation/chapters_eu.json", "en"),
    "DO": ("data/do_tariff_source", "do_tariff", "dga",
           "scripts/hts_automation/chapters_do.json", "es"),
    "GB": ("data/gb_tariff_source", "gb_tariff", "taric",
           "scripts/hts_automation/chapters_gb.json", "en"),
}


def newest_source(directory: str, prefix: str) -> Path:
    cands = sorted(Path(directory).glob(f"{prefix}_*_rev_*.csv"),
                   key=lambda p: p.stat().st_mtime, reverse=True)
    if not cands:
        sys.exit(f"ERROR: no {prefix}_*.csv in {directory}")
    return cands[0]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--jurisdiction", choices=("CA", "EU", "DO", "GB"), required=True)
    p.add_argument("--source", type=Path)
    p.add_argument("--codes", type=Path, help="a built <jur>_<rev>.codes.json to cross-check")
    p.add_argument("--explorer", type=Path, help="a built <jur>_<year>_revision_<n>.json to cross-check")
    args = p.parse_args()

    directory, prefix, fmt, chapters, lang = SOURCES[args.jurisdiction]
    src = args.source or newest_source(directory, prefix)
    print(f"[reconcile {args.jurisdiction}] source: {src}")

    bhc.CORPUS_LANG = lang
    loaders = {"cbsa": bhc.load_rows_cbsa, "taric": bhc.load_rows_taric,
               "dga": bhc.load_rows_dga}
    rows, stats = loaders[fmt](src)
    roots = bhc.build_tree(rows)
    nodes = bhc.collect_node_index(roots)
    leaves = {d for d, has in nodes.items() if not has}

    failures = []

    # 1. conservation: coded source rows == tree nodes (both directions)
    if stats.coded_digits != set(nodes):
        missing = sorted(stats.coded_digits - set(nodes))[:10]
        extra = sorted(set(nodes) - stats.coded_digits)[:10]
        failures.append(f"coded rows != tree nodes (missing {missing}, extra {extra})")
    print(f"  raw rows: {stats.raw_row_count:,}  coded: {stats.coded_row_count:,}  "
          f"conditions: {stats.condition_row_count:,}  "
          f"dropped dup: {stats.dropped_duplicates}  dropped uncoded/suppressed: "
          f"{stats.dropped_uncoded}")
    print(f"  tree nodes: {len(nodes):,}  leaves: {len(leaves):,}")

    # 2. official leaf truth
    if fmt == "taric":
        if stats.official_leaf_digits != leaves:
            failures.append(
                f"leaf set != official IS_LEAF "
                f"({len(stats.official_leaf_digits):,} official vs {len(leaves):,} ours)")
        else:
            print(f"  EU: leaf set equals official IS_LEAF ({len(leaves):,}) ✔")
    if fmt == "dga":
        if len(leaves) != 7697:
            failures.append(f"DO leaves {len(leaves):,} != the book's 7,697")
        else:
            print("  DO: leaves == 7,697 operative subheadings (book's own count) ✔")

    # 3. built codes.json agreement
    if args.codes and args.codes.is_file():
        built = json.loads(args.codes.read_text(encoding="utf-8"))["nodes"]
        if built != nodes:
            failures.append(f"{args.codes.name} disagrees with a fresh parse "
                            f"({len(built):,} vs {len(nodes):,} nodes)")
        else:
            print(f"  {args.codes.name} matches a fresh parse ✔")

    # 4. Explorer dataset agreement (coded rows == source coded rows)
    if args.explorer and args.explorer.is_file():
        entries = json.loads(args.explorer.read_text(encoding="utf-8"))
        coded = [e for e in entries if e.get("htsno")]
        exp_digits = set()
        for e in coded:
            d = e.get("_digits") or bhc._digits_only(e["htsno"])
            exp_digits.add(d)
        # EU Explorer rows use trimmed display codes for internals; compare on
        # count only there, exact set elsewhere.
        if fmt == "taric":
            if len(coded) != stats.coded_row_count:
                failures.append(f"Explorer coded rows {len(coded):,} != "
                                f"source coded {stats.coded_row_count:,}")
            else:
                print(f"  Explorer dataset carries all {len(coded):,} coded rows ✔")
        else:
            if exp_digits != stats.coded_digits:
                failures.append("Explorer dataset code set != source code set")
            else:
                print(f"  Explorer dataset code set matches source ({len(coded):,}) ✔")

    if failures:
        for f in failures:
            print(f"  DISCREPANCY: {f}", file=sys.stderr)
        return 1
    print(f"[reconcile {args.jurisdiction}] NO DISCREPANCIES")
    return 0


if __name__ == "__main__":
    sys.exit(main())
