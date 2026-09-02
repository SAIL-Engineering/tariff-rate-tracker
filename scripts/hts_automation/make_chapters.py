#!/usr/bin/env python3
"""make_chapters.py — derive a chapters file from source data.

Hand-authoring 99 chapter entries invites drift and duplicates (chapters.json
shipped with chapter 99 twice). Where the source itself carries chapter rows,
derive the file:

  make_chapters.py --source-format taric data/eu_tariff_source/eu_tariff_2026_rev_8.csv \
      --out scripts/hts_automation/chapters_eu.json

Output schema matches chapters.json: [{"chapter": "01", "description": ...}].
Section fields can be curated in afterwards; only `description` is consumed by
build_hts_corpus today.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


def from_taric(path: Path, lang: str = "en") -> list[dict]:
    out = []
    with path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            digits = (r.get("GOODS_CODE") or "").strip()
            if (r.get("SUFFIX") or "") == "80" and digits[2:] == "00000000":
                desc = " ".join((r.get("DESCRIPTION") or "").split())
                # Sentence-casing a shouted heading is only safe in English —
                # German would lose its noun capitalization; other languages
                # keep the published casing.
                if desc.isupper() and lang == "en":
                    desc = desc.capitalize()
                out.append({"chapter": digits[:2], "description": desc})
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("csv_path", type=Path)
    p.add_argument("--source-format", choices=("taric",), required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--lang", default="en",
                   help="language of the source CSV (casing rules)")
    p.add_argument("--sections", type=Path,
                   help="HS sections JSON ([{section, sectionTitle, start, "
                        "end}]) to enrich each chapter with section metadata")
    args = p.parse_args()

    chapters = from_taric(args.csv_path, args.lang)
    if args.sections:
        sections = json.loads(args.sections.read_text(encoding="utf-8"))
        for c in chapters:
            n = int(c["chapter"])
            for s in sections:
                if s["start"] <= n <= s["end"]:
                    c["section"] = s["section"]
                    c["sectionTitle"] = s["sectionTitle"]
                    break
    seen = set()
    for c in chapters:
        if c["chapter"] in seen:
            sys.exit(f"ERROR: duplicate chapter {c['chapter']}")
        seen.add(c["chapter"])
    args.out.write_text(json.dumps(chapters, indent=2, ensure_ascii=False) + "\n",
                        encoding="utf-8")
    print(f"Wrote {len(chapters)} chapters -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
