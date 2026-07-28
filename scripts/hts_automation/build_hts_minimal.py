#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build HTS line-based RAG artifacts (legacy output shape).

Outputs:
1. JSONL: one JSON object per line/chunk
2. CSV:   one row per line/chunk (single content column)

Example:
python3 build_hts_minimal.py hts_2026_revision_12.csv chapters.json v5_minimal2026rev12

-----------------------------------------------------------------------------
2026-07-27 — CORRECTNESS UPDATE. Three bugs in build_tree() were producing
breadcrumbs that stated the OPPOSITE of the truth, and one predicate was
dropping thousands of valid classification targets. Measured on US HTS 2026
rev 12: 9,477 of 19,949 breadcrumbs (47%) were factually wrong, and 3,453 leaf
codes were missing entirely.

  1. Condition rows did not own their indent level, so the next deeper row
     parented to the previous CODED row instead of to the condition's parent.
  2. Stale conditions leaked past the end of their group.
  3. Only the shallowest condition in a nested chain was captured.
  4. Records were emitted for 10-digit codes rather than for LEAVES, dropping
     every code that is terminal at 8 digits.

Each is documented inline at its fix site. See build_hts_corpus.py for the
full rationale and for the Pinecone-targeted record format.

THIS FILE IS A SYNCED COPY. The canonical implementation of the tree logic is
  tariff-rate-tracker/scripts/hts_automation/build_hts_corpus.py
and identical copies of THIS file live at
  sail-gtx-prerelease/public/data/scripts/v5_build_hts_minimal.py
  sail-gtx-prerelease/dist/data/scripts/v5_build_hts_minimal.py   (build output)
Four independent copies of this logic is how the bugs above survived. If you
change one, change them all.
-----------------------------------------------------------------------------
"""

import csv
import json
import sys
from pathlib import Path
from copy import deepcopy


def _clean_txt(txt: str) -> str:
    return (txt or "").strip().rstrip(":").strip()


def _digits_only(code: str) -> str:
    return "".join(ch for ch in (code or "") if ch.isdigit())


def _code_parts(code: str) -> dict:
    digits = _digits_only(code)
    return {
        "chapter": digits[:2] if len(digits) >= 2 else "",
        "heading": digits[:4] if len(digits) >= 4 else "",
        "subheading": digits[:6] if len(digits) >= 6 else "",
        "digits": digits,
    }


def load_rows(path: Path):
    rows = []
    with path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            clean = {k.strip(): (v.strip() if v else "") for k, v in r.items()}
            clean["_indent"] = int(clean.get("Indent") or 0)
            clean["_code"] = clean["HTS Number"]
            rows.append(clean)
    return rows


def load_chapters(path: Path):
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    return {c["chapter"]: c["description"] for c in data}


class Node(dict):
    def __init__(self, data: dict, edge_conds):
        super().__init__(deepcopy(data))
        # A CHAIN of condition rows, outermost first (fix 3).
        self["edgeConditions"] = list(edge_conds or [])
        self["children"] = []


def build_tree(raw_rows):
    roots = []
    level_node = {}
    level_cond = {}

    for row in raw_rows:
        ind, code, desc = row["_indent"], row["_code"], row["Description"]

        if not code:  # CONDITION row
            level_cond[ind] = desc
            level_cond = {k: v for k, v in level_cond.items() if k <= ind}
            # FIX 1: a condition row OCCUPIES its indent level. Of the 5,944
            # condition rows in US rev 12, 5,911 are followed by a coded row at
            # a DEEPER indent and none at an equal one. Failing to evict
            # level_node[ind] made the next deeper row parent to the last CODED
            # row at that indent. Rows 73-75 of rev 12:
            #     ind=1  0103.10.00.00  "Purebred breeding animals"
            #     ind=1  (condition)    "Other:"
            #     ind=2  0103.91.00     "Weighing less than 50 kg each"
            # attached 0103.91.00 under 0103.10.00.00 — asserting a code is a
            # purebred breeding animal when it is explicitly NOT one — and made
            # 0103.10.00.00 a non-leaf. 1,842 leaf codes were lost this way.
            level_node = {k: v for k, v in level_node.items() if k < ind}
            continue

        # FIX 2: expire stale conditions BEFORE resolving this node's own.
        # A condition at level k governs only rows nested under it; once a coded
        # row appears at level <= k the group has closed. Expiring with
        # `k <= ind` AFTER building the node let closed groups leak onto their
        # successors: 0101.30.00.00 ("Asses") and 0101.90 ("Other") both
        # inherited "Horses:" from the 0101.21/0101.29 group above them.
        level_cond = {k: v for k, v in level_cond.items() if k < ind}

        p_ind = ind - 1
        while p_ind not in level_node and p_ind >= 0:
            p_ind -= 1
        parent = level_node.get(p_ind)

        # FIX 3: collect the WHOLE condition chain between parent and node.
        # `level_cond.get(p_ind + 1)` took only the shallowest. Conditions nest
        # several deep, so 3004.90.92.06 kept "Other:" while "Anti-infective
        # medicaments:" and "Antivirals:" were dropped — and its siblings
        # .08/.10/.12/.15 are all described merely as "Other", separated ONLY by
        # those chains (Antifungals, Antiprotozoals, Sulfonamides).
        edge_conds = [level_cond[k] for k in sorted(level_cond) if p_ind < k <= ind]

        node = Node(row, edge_conds)
        if parent is None:
            roots.append(node)
        else:
            parent["children"].append(node)

        level_node[ind] = node
        level_node = {k: v for k, v in level_node.items() if k <= ind}

    return roots


def make_path_text(path_nodes, this_node, chapters_map):
    """
    Build a fully self-contained breadcrumb string like:
    45 Cork and articles of cork | 4503 Articles of natural cork |
    4503.90 Other | 4503.90.40.00 Wallcoverings, backed with paper or otherwise reinforced
    """
    full_code = (this_node.get("HTS Number") or "").strip()
    chapter = _code_parts(full_code)["chapter"]

    parts = []
    if chapter and chapter in chapters_map:
        chapter_desc = _clean_txt(chapters_map[chapter])
        if chapter_desc:
            parts.append(f"{chapter} {chapter_desc}")

    for p in path_nodes + [this_node]:
        code = (p.get("HTS Number") or "").strip()
        desc = _clean_txt(p.get("Description", ""))
        if code and desc:
            part = f"{code} {desc}"
            if not parts or parts[-1] != part:
                parts.append(part)

    return " | ".join(parts)


def flatten_tree_to_records(roots, chapters_map):
    """FIX 4: emit one record per LEAF, not per 10-digit code.

    The old predicate `len(digits) == 10` silently dropped every code that is
    terminal at 8 digits — 3,453 of them in US rev 12. CBP defines no 10-digit
    suffix for those, so they are legitimate final classification targets and
    their retrieval recall was structurally zero. A leaf is full-depth by
    definition, which is also correct for schedules that top out at 8 digits.
    """
    records = []

    def dfs(n, path):
        code = (n.get("HTS Number") or "").strip()

        if code and not n["children"]:
            path_text = make_path_text(path, n, chapters_map)
            if path_text:
                parts = _code_parts(code)
                records.append({
                    "code": code,
                    "chapter": parts["chapter"],
                    "heading": parts["heading"],
                    "subheading": parts["subheading"],
                    "depth": len(parts["digits"]),
                    "text": f"{code} = {path_text}",
                })

        for c in n["children"]:
            dfs(c, path + [n])

    for root in roots:
        dfs(root, [])

    return records


def write_jsonl(records, path: Path):
    with path.open("w", encoding="utf-8") as fh:
        for record in records:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def write_csv_single_column(records, path: Path):
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["content"])
        for record in records:
            writer.writerow([record["text"]])


def main(csv_path, chapters_path, out_stem):
    csv_path = Path(csv_path)
    chapters_path = Path(chapters_path)
    out_stem = Path(out_stem)

    raw_rows = load_rows(csv_path)
    chapters_map = load_chapters(chapters_path)
    roots = build_tree(raw_rows)
    records = flatten_tree_to_records(roots, chapters_map)

    jsonl_path = out_stem.with_suffix(".jsonl")
    csv_out_path = out_stem.with_suffix(".csv")

    write_jsonl(records, jsonl_path)
    write_csv_single_column(records, csv_out_path)

    by_depth = {}
    for r in records:
        by_depth[r["depth"]] = by_depth.get(r["depth"], 0) + 1
    depth_summary = ", ".join(f"{k}-digit: {v:,}" for k, v in sorted(by_depth.items()))

    print(f"Wrote {len(records):,} leaf rows → {jsonl_path}")
    print(f"Wrote {len(records):,} leaf rows → {csv_out_path}")
    print(f"  ({depth_summary})")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(
            "usage: python3 build_hts_minimal.py hts_2026_revision_12.csv chapters.json minimalrev12"
        )
        sys.exit(1)

    main(*sys.argv[1:])
