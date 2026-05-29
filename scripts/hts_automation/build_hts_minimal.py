#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Tue Mar 17 14:46:44 2026

@author: wijreid
"""

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build HTS line-based RAG artifacts.

Outputs:
1. JSONL: one JSON object per line/chunk
2. CSV:   one row per line/chunk (single content column)

Example:
python3 v5_build_hts_minimal.py hts_2026_revision_8.csv chapters.json v5_minimal2026rev8
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


def _is_10_digit_code(code: str) -> bool:
    return len(_digits_only(code)) == 10


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
    def __init__(self, data: dict, edge_cond: str | None):
        super().__init__(deepcopy(data))
        self["edgeCondition"] = edge_cond or ""
        self["children"] = []


def build_tree(raw_rows):
    roots: list[Node] = []
    level_node: dict[int, Node] = {}
    level_cond: dict[int, str] = {}

    for row in raw_rows:
        ind, code, desc = row["_indent"], row["_code"], row["Description"]

        if not code:  # CONDITION row
            level_cond[ind] = desc
            level_cond = {k: v for k, v in level_cond.items() if k <= ind}
            continue

        p_ind = ind - 1
        while p_ind not in level_node and p_ind >= 0:
            p_ind -= 1
        parent = level_node.get(p_ind)
        edge_cond = level_cond.get(p_ind + 1)

        node = Node(row, edge_cond)
        if parent is None:
            roots.append(node)
        else:
            parent["children"].append(node)

        level_node[ind] = node
        level_node = {k: v for k, v in level_node.items() if k <= ind}
        level_cond = {k: v for k, v in level_cond.items() if k <= ind}

    return roots


def make_path_text(path_nodes, this_node, chapters_map):
    """
    Build a fully self-contained breadcrumb string like:
    45 Cork and articles of cork | 4503 Articles of natural cork |
    4503.90 Other | 4503.90.40.00 Wallcoverings, backed with paper or otherwise reinforced
    """
    full_code = (this_node.get("HTS Number") or "").strip()
    parts_info = _code_parts(full_code)
    chapter = parts_info["chapter"]

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
    records = []

    def dfs(n, path):
        code = (n.get("HTS Number") or "").strip()

        if _is_10_digit_code(code):
            path_text = make_path_text(path, n, chapters_map)
            if path_text:
                parts = _code_parts(code)
                records.append({
                    "code": code,
                    "chapter": parts["chapter"],
                    "heading": parts["heading"],
                    "subheading": parts["subheading"],
                    "text": f"{code} = {path_text}"
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

    print(f"Wrote {len(records):,} 10-digit rows → {jsonl_path}")
    print(f"Wrote {len(records):,} 10-digit rows → {csv_out_path}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(
            "usage: python3 v5_build_hts_minimal.py hts_2025_revision_21.csv chapters.json minimalrev21"
        )
        sys.exit(1)

    main(*sys.argv[1:])
    
    
'''
Yes — that command is correct.

Use:

```bash
python3 build_hts_minimal.py hts_2025_revision_21.csv chapters.json minimalrev21
```

## What each argument means

The script expects **3 arguments** after the file name:

```bash
python3 build_hts_minimal.py <input_hts_csv> <chapters_json> <output_stem>
```

So in your case:

* `build_hts_minimal.py` → the Python script
* `hts_2025_revision_21.csv` → the HTS source CSV
* `chapters.json` → the chapter-description lookup file
* `minimalrev21` → the **output stem**, not a full filename

## Why `minimalrev21` is not a full filename

Because the script automatically creates **two files** from that base name:

* `minimalrev21.jsonl`
* `minimalrev21.csv`

So this:

```bash
python3 build_hts_minimal.py hts_2025_revision_21.csv chapters.json minimalrev21
```

produces:

```bash
minimalrev21.jsonl
minimalrev21.csv
```

## Folder structure example

If your files are all in the same folder:

```bash
your_folder/
├── build_hts_minimal.py
├── hts_2025_revision_21.csv
├── chapters.json
```

then:

```bash
cd your_folder
python3 build_hts_minimal.py hts_2025_revision_21.csv chapters.json minimalrev21
```

## If the files are in different folders

You can also use paths:

```bash
python3 build_hts_minimal.py data/hts_2025_revision_21.csv data/chapters.json outputs/minimalrev21
```

That would create:

```bash
outputs/minimalrev21.jsonl
outputs/minimalrev21.csv
```

## Important detail about the output stem

Do **not** include `.jsonl` or `.csv` in the third argument.

Good:

```bash
python3 build_hts_minimal.py hts_2025_revision_21.csv chapters.json minimalrev21
```

Not ideal:

```bash
python3 build_hts_minimal.py hts_2025_revision_21.csv chapters.json minimalrev21.jsonl
```

because the script would then treat that as the base and may generate awkward names.

## What you should see after running

Something like:

```bash
Wrote 12,345 10-digit rows → minimalrev21.jsonl
Wrote 12,345 10-digit rows → minimalrev21.csv
```

## If Python 3 is not found

Sometimes the command is:

```bash
python build_hts_minimal.py hts_2025_revision_21.csv chapters.json minimalrev21
```

But `python3` is usually the safest.

## Quick summary

Run it like this:

```bash
python3 build_hts_minimal.py hts_2025_revision_21.csv chapters.json minimalrev21
```

Meaning:

```bash
python3 <script> <hts_csv> <chapters_json> <output_base_name>
```

And it outputs:

```bash
minimalrev21.jsonl
minimalrev21.csv
```

If you want, I can also give you a version of the script that lets you explicitly pass two output filenames instead of one shared output stem.

'''