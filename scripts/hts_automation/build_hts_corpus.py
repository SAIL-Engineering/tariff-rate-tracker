#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_hts_corpus.py — build the Pinecone retrieval corpus for a tariff schedule.

Successor to build_hts_minimal.py (which stays in place, unchanged, producing the
legacy Ragie CSV until the Pinecone path is validated and step 4 of the rollout is
switched over).

Four differences from build_hts_minimal.py, each deliberate:

 1. EMITS LEAVES, NOT 10-DIGIT LINES.
    build_hts_minimal.py emits a record only when the code has exactly 10 digits.
    In US HTS 2026 rev 12 there are 23,401 leaf codes: 19,948 at 10 digits and
    3,453 at 8. CBP defines no 10-digit suffix for those 3,453 — they are
    legitimate final classification targets, and under the old predicate they were
    absent from the corpus entirely, giving them a structural recall of ZERO.
    A leaf is "full depth" by definition, whether it sits at 8 or 10 digits, which
    also makes this correct for jurisdictions whose schedules top out at 8.

 2. SPLITS EMBEDDED TEXT FROM DISPLAYED TEXT.
    `chunk_text` is what Pinecone embeds: prose only, no codes. The HTS code
    appeared TWICE in the old single string (once as the `code = ` prefix, once as
    the final breadcrumb segment) and every intermediate segment carried its own
    code. Digit runs tokenize poorly and carry no semantic signal, so they dilute a
    vector whose only job is matching product prose to tariff prose.
    `display_text` is BYTE-IDENTICAL to build_hts_minimal.py's `text` and is what
    reaches the classification prompt — so Stage 3 sees exactly what it sees today
    and this change cannot regress inference.

 3. RESOLVES BASKET PROVISIONS AGAINST THEIR SIBLINGS.
    5,806 rows in rev 12 have the description "Other" (plus 562 "Other:"). Those
    lines carry almost no semantic content, so no embedding can retrieve them on
    similarity — and a large share of real classifications land there. What defines
    a basket provision is what it is NOT, so we render it as
    "Other, other than: <siblings>" using the siblings that share its condition.

 4. RECOVERS THE EDGE CONDITION.
    build_tree() already captures condition rows (rows with no HTS number, e.g.
    "Weighing less than 90 kg each:") into node["edgeCondition"] — 5,944 of them in
    rev 12 — and make_path_text() never reads it. That is discriminative statutory
    text being discarded for free. It goes into `chunk_text` only; `display_text`
    stays byte-identical per (2).

Outputs:
  <stem>.jsonl          one record per leaf, ready for Pinecone upsertRecords
  <stem>.manifest.json  {record_count, jurisdiction, revision, source_sha256, ...}

Example:
  python3 build_hts_corpus.py \
      data/hts_archives_csv/hts_2026_rev_12.csv \
      scripts/hts_automation/chapters.json \
      out/us_2026_rev_12 \
      --jurisdiction US --revision 2026_rev_12 --max-depth 10
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path

# A leaf whose description is one of these is a residual/basket provision: it is
# defined by exclusion from its siblings rather than by its own text.
# Per-language: the DR corpus is Spanish ("Los demás"). CORPUS_LANG is set once
# from --lang in main(); the default keeps US/CA/EU output byte-identical.
BASKET_RE = re.compile(r"^(other|others|other,?\s+nesoi|nesoi)$", re.IGNORECASE)
_BASKET_RES = {
    "en": BASKET_RE,
    "es": re.compile(r"^(los\s+dem[áa]s|las\s+dem[áa]s|otros|otras|otro|otra)$",
                     re.IGNORECASE),
}
_EXCLUSION_TEMPLATES = {
    "en": "{desc}, other than: {clause}",
    "es": "{desc}, excepto: {clause}",
}
CORPUS_LANG = "en"

# Cap how many siblings get named in an exclusion clause. Some baskets have
# dozens; naming all of them bloats the vector without adding discrimination.
MAX_SIBLINGS_NAMED = 6

# llama-text-embed-v2 truncates silently at 2048 tokens (~8000 chars at the
# usual ~4 chars/token). We truncate first, at a lower bound, so the loss is
# explicit and counted rather than invisible.
#
# Almost nothing hits this: US p99 is 260 tokens and the longest record is 591.
# The exceptions are a handful of Canadian Chapter 99 provisions whose OWN
# description is an enumeration — 9914.00.00 runs 52,757 characters of chemical
# names. Those would lose their tail to the embedder regardless; the breadcrumb
# prefix that identifies the provision is what carries the retrievable meaning.
CHUNK_TEXT_CHAR_WARN = 6000

# display_text reaches the classification prompt, and 30 chunks are sent per
# call. One 52k-character record would dominate the context window on its own.
DISPLAY_TEXT_CHAR_CAP = 4000

TRUNCATION_MARKER = " […truncated]"


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


def _is_basket(desc: str) -> bool:
    return bool(_BASKET_RES[CORPUS_LANG].match(_clean_txt(desc)))


@dataclass
class LoadStats:
    """Row accounting from a loader, carried through to the manifest and the
    completeness assertion. `coded_digits` is the post-dedup set of digit
    strings that MUST appear in the built tree — the source-row conservation
    invariant (exit 5/6 in main) is checked against exactly this set."""
    raw_row_count: int = 0
    coded_row_count: int = 0
    condition_row_count: int = 0
    dropped_duplicates: int = 0
    dropped_uncoded: int = 0
    coded_digits: set = field(default_factory=set)
    # Officially published leaf flags (EU: Declarable codes IS_LEAF). When
    # present, the builder asserts its own tree's leaf set equals this exactly
    # (exit 7) — a given-truth completeness check no inference can beat.
    official_leaf_digits: set | None = None


def _parse_units(raw: str) -> list[str]:
    """The CSV stores units as a JSON array string, e.g. '["doz.","kg"]'."""
    raw = (raw or "").strip()
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, list):
            return [str(u).strip() for u in parsed if str(u).strip()]
    except (ValueError, TypeError):
        pass
    return [raw]


# ── CBSA (Canada) ────────────────────────────────────────────────────────────
# The Canadian source has no Indent column — the USITC one does. Hierarchy is
# instead implied by the TARIFF code's digit length, which nests cleanly:
#
#   01.01           4 digits   heading
#   0101.2          5          subheading level
#   0101.21.00      8          tariff item
#   0101.21.00.00  10          statistical suffix
#
# Mapping length to an indent rank lets the SAME build_tree() run for both
# jurisdictions. That matters more than the small amount of code it saves: three
# separate copies of this tree logic is exactly how the US breadcrumbs ended up
# wrong for 47% of lines, and a second independent CA implementation would be a
# fourth copy waiting to drift.
#
# INDENT IS DERIVED FROM ANCESTOR COUNT, NOT FROM DIGIT LENGTH.
#
# Digit length is the obvious mapping (4->0, 5->1, ... 10->6) and it is wrong.
# 353 Canadian codes have NO ancestor present in the file at all — Chapter 99
# special provisions like 9903.00.00, where the 4-digit heading row simply does
# not exist. Given a fixed length->indent map those land at indent 4 with nothing
# above them, so build_tree()'s "walk up to the nearest present level" finds
# whatever unrelated node was last seen at a shallower indent and adopts them.
#
# The symptom was unmistakable once the length canary fired: all 13 oversized
# records had breadcrumbs beginning
#   "Special classification provisions - commercial > A live specimen of th..."
# i.e. a dozen unrelated Chapter 99 provisions all inheriting one arbitrary
# sibling as their parent, and concatenating its enormous text.
#
# Counting ancestors instead makes indent agree with digit-prefix parentage by
# construction: a code with no ancestors is a root, and every other code sits
# exactly one level below its nearest present ancestor. Self-correcting, and it
# needs no special case for the orphans.
def _cbsa_indent(digits: str, all_codes: set[str]) -> int:
    return sum(1 for k in range(4, len(digits)) if digits[:k] in all_codes)


def load_rows_cbsa(path: Path):
    """Normalise the CBSA export into the same row shape load_rows() produces.

    Differences from the USITC file, all handled here:
      * no Indent column          -> derived from ancestor count (see above)
      * DESC2/DESC3               -> CONTINUATIONS of DESC1, not hierarchy levels.
                                     Only 2 rows use them (the giant Ch.99
                                     pharmaceutical-ingredient lists), and
                                     treating them as levels would corrupt those.
      * every row carries a code   -> unlike USITC there are no code-less
                                     condition rows; the CA equivalents are
                                     colon-terminated CODED rows ("0101.2
                                     Horses:"), which become ordinary breadcrumb
                                     levels. 1,924 of them, and the v4 pipeline
                                     dropped all of them.
      * one exact duplicate code   -> 5206.41.00.00 appears at two row_ids with
                                     identical date/description/UOM. First wins.
    """
    raw = []
    seen: set[str] = set()
    stats = LoadStats()
    dupes = 0
    with path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            stats.raw_row_count += 1
            code = (r.get("TARIFF") or "").strip()
            digits = _digits_only(code)
            if not digits:
                stats.dropped_uncoded += 1
                continue
            if digits in seen:
                dupes += 1
                continue
            seen.add(digits)
            # Collapse ALL internal whitespace (the Access export carries
            # literal newlines inside long descriptions; T2026-1 introduced
            # hundreds). Embedded newlines corrupt chunk/display text and
            # register as false "redescriptions" in the cross-revision diff.
            desc = " ".join(" ".join(
                (r.get(k) or "").split())
                for k in ("DESC1", "DESC2", "DESC3")
                if (r.get(k) or "").strip()
            )
            raw.append((code, digits, desc, (r.get("UOM") or "").strip()))
    if dupes:
        print(f"  note: skipped {dupes} duplicate CBSA code(s)", file=sys.stderr)
    stats.dropped_duplicates = dupes
    stats.coded_row_count = len(raw)
    stats.coded_digits = set(seen)

    rows = [{
        "HTS Number": code,
        "Description": desc,
        # Raw string, not a JSON array like the USITC file. _parse_units
        # tolerates both.
        "Unit of Quantity": uom,
        "_indent": _cbsa_indent(digits, seen),
        "_code": code,
    } for code, digits, desc, uom in raw]

    # build_tree() requires document order — a parent must appear before its
    # children. Verify rather than trust: a violation would silently reparent
    # nodes, which is the failure mode this whole builder exists to avoid.
    emitted: set[str] = set()
    for (code, digits, _, _) in raw:
        for k in range(4, len(digits)):
            anc = digits[:k]
            if anc in seen and anc not in emitted:
                raise SystemExit(
                    f"ERROR: {code} precedes its ancestor {anc}; "
                    f"input is not in document order"
                )
        emitted.add(digits)
    return rows, stats


# ── EU TARIC ─────────────────────────────────────────────────────────────────
# Source: the canonical CSV emitted by acquire/eu_taric.py (one row per
# nomenclature line, already joined with the official Declarable-codes
# IS_LEAF flag and carrying a computed INDENT — 0 chapter / 1 heading /
# 1 + dash-count otherwise; verified clean for 2026-08).
#
# SUFFIX 80 is a real nomenclature line; 10..70 are grouping rows -> mapped to
# CONDITION rows, the same construct as USITC's uncoded rows, so ONE
# build_tree() serves the EU too. Codes are stored as the full zero-padded
# 10-digit TARIC form (that is what an EU import declaration carries and what
# the report parser normalizes to), so `digits` is 10 for every node and
# hierarchy comes entirely from INDENT.
def _taric_display(digits: str, full: bool) -> str:
    """Book-style display: leaves show the full declarable 10-digit form;
    internal levels trim trailing zero-pairs (0101000000 -> 0101,
    0101210000 -> 0101.21) exactly as the printed nomenclature does."""
    if not full:
        while len(digits) > 4 and digits.endswith("00"):
            digits = digits[:-2]
    segs = [digits[:4]] + [digits[i:i + 2] for i in range(4, len(digits), 2)]
    return ".".join(segs)


def load_rows_taric(path: Path):
    rows = []
    stats = LoadStats()
    stats.official_leaf_digits = set()
    seen: set[str] = set()
    with path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            stats.raw_row_count += 1
            digits = (r.get("GOODS_CODE") or "").strip()
            suffix = (r.get("SUFFIX") or "").strip()
            desc = " ".join((r.get("DESCRIPTION") or "").split())
            indent = int(r.get("INDENT") or 0)
            if suffix != "80":
                stats.condition_row_count += 1
                rows.append({"HTS Number": "", "Description": desc,
                             "Unit of Quantity": "", "_indent": indent,
                             "_code": ""})
                continue
            if len(digits) != 10 or not digits.isdigit():
                raise SystemExit(f"ERROR: bad GOODS_CODE {digits!r} in {path.name}")
            if digits[2:] == "00000000":
                # Chapter rows duplicate the chapters file (which prefixes
                # every breadcrumb already) and are never classification
                # targets — dropping them makes headings roots, exactly like
                # the USITC file, which has no chapter rows either.
                stats.dropped_uncoded += 1
                continue
            if digits in seen:
                raise SystemExit(f"ERROR: duplicate active TARIC code {digits}")
            seen.add(digits)
            stats.coded_row_count += 1
            stats.coded_digits.add(digits)
            official_leaf = (r.get("IS_LEAF") or "").strip() == "1"
            if official_leaf:
                stats.official_leaf_digits.add(digits)
            display = _taric_display(digits, full=official_leaf)
            rows.append({"HTS Number": display,
                         "Description": desc,
                         "Unit of Quantity": "",
                         "_indent": indent,
                         "_code": display,
                         "_digits": digits})
    return rows, stats


# ── DGA (Dominican Republic) ─────────────────────────────────────────────────
# Source: the user-transcribed Arancel de Aduanas CSV (Spanish; DGA publishes
# PDF only). Hierarchy is encoded as LEADING DASHES in the description —
# heading rows (4-digit "01.01") carry none; each nesting level adds one.
# Rows with no code and a trailing ":" are grouping rows -> condition rows.
# Leaves are 8-digit; DR never uses 10.
#
# Quirks handled here, all real and counted:
#   * "[05.03]"-style bracketed codes are suppressed/deleted HS headings with
#     empty descriptions -> dropped (they are not classifiable provisions).
#   * one stray bare chapter row ("77", blank description) -> dropped.
#   * three 6-digit codes appear twice (e.g. 7113.19), the second time as a
#     nested "Los demás:" group header -> the second occurrence becomes a
#     CONDITION row, keeping its text without colliding on the code.
_DGA_DASH_RE = re.compile(r"^(\s*-\s*)+")


def load_rows_dga(path: Path):
    rows = []
    stats = LoadStats()
    seen: set[str] = set()
    with path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            stats.raw_row_count += 1
            clean = {k.strip(): (v.strip() if v else "") for k, v in r.items()
                     if k is not None}
            code_raw = clean.get("Código", "")
            desc_raw = clean.get("Designación de la mercancía", "")
            m = _DGA_DASH_RE.match(desc_raw)
            dashes = m.group(0).count("-") if m else 0
            desc = " ".join(desc_raw[m.end():].split()) if m else " ".join(desc_raw.split())

            if "[" in code_raw:                       # suppressed heading
                stats.dropped_uncoded += 1
                continue
            digits = _digits_only(code_raw)
            if digits and len(digits) < 4:            # stray bare chapter row
                stats.dropped_uncoded += 1
                continue

            is_condition = not digits
            if digits and digits in seen:
                if desc.endswith(":") or _is_basket(desc):
                    is_condition = True               # repeated group header
                    stats.dropped_duplicates += 1
                else:
                    raise SystemExit(f"ERROR: duplicate DGA code {code_raw!r} "
                                     f"with non-group description {desc!r}")

            if is_condition:
                if not desc:
                    stats.dropped_uncoded += 1
                    continue
                stats.condition_row_count += 1
                rows.append({"HTS Number": "", "Description": desc,
                             "Unit of Quantity": "", "_indent": dashes,
                             "_code": ""})
                continue

            seen.add(digits)
            stats.coded_row_count += 1
            stats.coded_digits.add(digits)
            rows.append({"HTS Number": code_raw, "Description": desc,
                         "Unit of Quantity": "", "_indent": dashes,
                         "_code": code_raw})
    return rows, stats


def load_rows(path: Path):
    rows = []
    stats = LoadStats()
    with path.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            stats.raw_row_count += 1
            clean = {k.strip(): (v.strip() if v else "") for k, v in r.items()}
            clean["_indent"] = int(clean.get("Indent") or 0)
            clean["_code"] = clean["HTS Number"]
            digits = _digits_only(clean["_code"])
            if digits:
                stats.coded_row_count += 1
                stats.coded_digits.add(digits)
            else:
                stats.condition_row_count += 1
            rows.append(clean)
    return rows, stats


def load_chapters(path: Path):
    """Full chapter records keyed by chapter number.

    Returns {chapter: {"description": ..., ...everything else in the file}} so
    section titles and any future fields stop being discarded at parse time.
    Duplicate chapter keys are a config bug (chapters.json shipped with chapter
    99 twice and dict last-wins hid it) — fail loudly.
    """
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    out: dict[str, dict] = {}
    for c in data:
        ch = c["chapter"]
        if ch in out:
            raise SystemExit(f"ERROR: duplicate chapter {ch!r} in {path.name}")
        out[ch] = dict(c)
    return out


class Node(dict):
    def __init__(self, data: dict, edge_conds: list[str] | None):
        super().__init__(deepcopy(data))
        # A CHAIN of condition rows, outermost first — see build_tree().
        self["edgeConditions"] = list(edge_conds or [])
        self["children"] = []


def build_tree(raw_rows):
    """Indent-tree reconstruction, with one correctness fix over
    build_hts_minimal.py — see the CONDITION-row branch below.

    Everything else is unchanged; this reconstruction is why the breadcrumbs are
    good and should not be otherwise touched."""
    roots: list[Node] = []
    level_node: dict[int, Node] = {}
    level_cond: dict[int, str] = {}

    for row in raw_rows:
        ind, code, desc = row["_indent"], row["_code"], row["Description"]

        if not code:  # CONDITION row
            level_cond[ind] = desc
            level_cond = {k: v for k, v in level_cond.items() if k <= ind}
            # BUG FIX vs build_hts_minimal.py.
            #
            # A condition row OCCUPIES its indent level: of the 5,944 condition
            # rows in US rev 12, 5,911 are followed by a coded row at a DEEPER
            # indent and none at an equal one. Upstream failed to evict
            # level_node[ind], so the next deeper coded row parented to the last
            # CODED row at that indent instead of to the condition's own parent.
            #
            # Concretely, rows 73-75 of rev 12:
            #     ind=1  0103.10.00.00  "Purebred breeding animals"
            #     ind=1  (condition)    "Other:"
            #     ind=2  0103.91.00     "Weighing less than 50 kg each"
            # attached 0103.91.00 under 0103.10.00.00, producing the breadcrumb
            # "Live swine > Purebred breeding animals > Weighing less than 50 kg"
            # for a code that is explicitly NOT a purebred breeding animal — the
            # exact opposite of the truth — and simultaneously made
            # 0103.10.00.00 a non-leaf, dropping a real classification target.
            # 1,842 leaf codes were lost this way.
            level_node = {k: v for k, v in level_node.items() if k < ind}
            continue

        # BUG FIX vs build_hts_minimal.py (2/2): expire stale conditions BEFORE
        # resolving this node's own.
        #
        # A condition at level k governs only the rows nested under it. Once a
        # coded row appears at level <= k, that group has closed. Upstream kept
        # conditions with `k <= ind` and expired them only AFTER building the
        # node, so a closed group leaked onto its successors: 0101.30.00.00
        # ("Asses") and 0101.90 ("Other") both inherited the "Horses:" condition
        # that belonged to the 0101.21/0101.29 group, labelling asses as horses.
        #
        # Conditions never govern a row at their own indent (measured across all
        # 5,944 condition rows in rev 12: the next coded row is deeper in 5,911
        # cases and shallower in 33 — never equal), so expiring k >= ind is safe.
        level_cond = {k: v for k, v in level_cond.items() if k < ind}

        p_ind = ind - 1
        while p_ind not in level_node and p_ind >= 0:
            p_ind -= 1
        parent = level_node.get(p_ind)

        # BUG FIX vs build_hts_minimal.py (3/3): collect the WHOLE condition
        # chain between the parent and this node, not just the shallowest one.
        #
        # Upstream used `level_cond.get(p_ind + 1)`, which takes a single
        # condition. Conditions nest several deep, so 3004.90.92.06 inherited
        # only "Other:" while "Anti-infective medicaments:" and "Antivirals:" —
        # the text that actually distinguishes it — were dropped. Its siblings
        # .08/.10/.12/.15 are likewise all described merely as "Other" and are
        # separated ONLY by their condition chains (Antifungals, Antiprotozoals,
        # Sulfonamides), so discarding the chain collapsed 20 distinct medicament
        # baskets into one indistinguishable string.
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
    """UNCHANGED from build_hts_minimal.py — produces `display_text` verbatim so
    the classification prompt receives byte-identical input to today."""
    full_code = (this_node.get("HTS Number") or "").strip()
    chapter = _code_parts(full_code)["chapter"]

    parts = []
    if chapter and chapter in chapters_map:
        chapter_desc = _clean_txt(chapters_map[chapter]["description"])
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


def resolve_description(node, parent) -> str:
    """Render a node's description, expanding basket provisions into what they
    exclude. `parent` is None for roots.

    Siblings are scoped to those sharing the node's edgeCondition — under a
    condition row like "Horses:", "Other" means "other horses", not "other
    anything in the heading". Falls back to all siblings when that grouping is
    empty (nodes with no condition)."""
    desc = _clean_txt(node.get("Description", ""))
    if not desc or parent is None or not _is_basket(desc):
        return desc

    own_cond = tuple(node.get("edgeConditions") or ())
    siblings = [c for c in parent["children"] if c is not node]

    same_cond = [c for c in siblings if tuple(c.get("edgeConditions") or ()) == own_cond]
    pool = same_cond or siblings

    named = []
    for sib in pool:
        sib_desc = _clean_txt(sib.get("Description", ""))
        # Don't define one basket by reference to another.
        if sib_desc and not _is_basket(sib_desc) and sib_desc not in named:
            named.append(sib_desc)

    if not named:
        return desc

    truncated = len(named) > MAX_SIBLINGS_NAMED
    shown = named[:MAX_SIBLINGS_NAMED]
    clause = "; ".join(shown) + ("; ..." if truncated else "")
    return _EXCLUSION_TEMPLATES[CORPUS_LANG].format(desc=desc, clause=clause)


def make_chunk_text(path_nodes, this_node, chapters_map) -> str:
    """The EMBEDDED text: prose only, no codes, baskets resolved, edge conditions
    folded in as extra breadcrumb levels."""
    full_code = (this_node.get("HTS Number") or "").strip()
    chapter = _code_parts(full_code)["chapter"]

    segments: list[str] = []
    if chapter and chapter in chapters_map:
        chapter_desc = _clean_txt(chapters_map[chapter]["description"])
        if chapter_desc:
            segments.append(chapter_desc)

    chain = path_nodes + [this_node]
    for i, node in enumerate(chain):
        parent = chain[i - 1] if i > 0 else None

        # The condition rows that qualified this node ("Horses:", "Antivirals:",
        # "Weighing less than 90 kg each:") each narrow within the parent, so
        # they read naturally as their own breadcrumb levels. For deeply nested
        # baskets this chain is the ONLY thing distinguishing siblings that are
        # all described as "Other".
        for cond in node.get("edgeConditions", []):
            cond = _clean_txt(cond)
            if cond and (not segments or segments[-1] != cond):
                segments.append(cond)

        desc = resolve_description(node, parent)
        if desc and (not segments or segments[-1] != desc):
            segments.append(desc)

    return " > ".join(segments)


def collect_node_index(roots) -> dict:
    """Every code in the schedule mapped to whether it has children.

    This is what the server-side code validator needs and it cannot be derived
    from the corpus, because the corpus holds LEAVES ONLY. Telling "you stopped
    one level short" (incomplete) apart from "that code does not exist"
    (not_found) requires seeing internal nodes too.

    Emitting it here rather than re-parsing the source on the server keeps ONE
    tree implementation — the same reason load_rows_cbsa() feeds build_tree()
    instead of having its own. It also means the validator works for every
    jurisdiction, not just the one whose raw dataset happens to ship with the
    server: without this, Canada had no hallucination guard at all.
    """
    nodes: dict[str, bool] = {}

    def walk(n):
        code = (n.get("HTS Number") or "").strip()
        digits = n.get("_digits") or _digits_only(code)
        if digits:
            nodes[digits] = bool(n["children"])
        for c in n["children"]:
            walk(c)

    for root in roots:
        walk(root)
    return nodes


def flatten_tree_to_records(roots, chapters_map, jurisdiction, revision):
    """Emit one record per LEAF (a node with no children) — see module docstring
    point 1. The old predicate `len(digits) == 10` silently dropped every code
    that is terminal at 8 digits."""
    records = []
    depth_hist = Counter()
    truncated = Counter()

    def dfs(node, path):
        code = (node.get("HTS Number") or "").strip()
        is_leaf = not node["children"]

        if is_leaf and code:
            # A loader may provide `_digits` when the DISPLAY code is trimmed
            # (EU internal levels print as the book does — 0101.21 — while the
            # canonical identity stays the full zero-padded TARIC form).
            digits = node.get("_digits") or _code_parts(code)["digits"]
            parts = {
                "chapter": digits[:2] if len(digits) >= 2 else "",
                "heading": digits[:4] if len(digits) >= 4 else "",
                "subheading": digits[:6] if len(digits) >= 6 else "",
            }
            display_text = make_path_text(path, node, chapters_map)
            chunk_text = make_chunk_text(path, node, chapters_map)

            if display_text and chunk_text:
                if len(chunk_text) > CHUNK_TEXT_CHAR_WARN:
                    chunk_text = chunk_text[:CHUNK_TEXT_CHAR_WARN - len(TRUNCATION_MARKER)] + TRUNCATION_MARKER
                    truncated["chunk"] += 1
                if len(display_text) > DISPLAY_TEXT_CHAR_CAP:
                    display_text = display_text[:DISPLAY_TEXT_CHAR_CAP - len(TRUNCATION_MARKER)] + TRUNCATION_MARKER
                    truncated["display"] += 1
                depth_hist[len(digits)] += 1
                parent = path[-1] if path else None
                units = _parse_units(node.get("Unit of Quantity", ""))
                records.append({
                    "_id": f"{jurisdiction}|{revision}|{digits}",
                    "chunk_text": chunk_text,
                    "display_text": f"{code} = {display_text}",
                    "code": code,
                    "chapter": parts["chapter"],
                    "heading": parts["heading"],
                    "subheading": parts["subheading"],
                    "depth": len(digits),
                    "unit": "/".join(units),
                    "is_basket": _is_basket(node.get("Description", "")),
                    "jurisdiction": jurisdiction,
                    "revision": revision,
                    "kind": "line",
                })

        for child in node["children"]:
            dfs(child, path + [node])

    for root in roots:
        dfs(root, [])

    return records, depth_hist, truncated


def write_jsonl(records, path: Path):
    with path.open("w", encoding="utf-8") as fh:
        for record in records:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("csv_path")
    p.add_argument("chapters_path")
    p.add_argument("out_stem", help="Output base name; .jsonl and .manifest.json are appended")
    p.add_argument("--jurisdiction", required=True, help="ISO alpha-2, e.g. US")
    p.add_argument("--revision", required=True, help="e.g. 2026_rev_12")
    p.add_argument("--source-format", choices=("usitc", "cbsa", "taric", "dga"), default="usitc",
                   help="usitc = US CSV with an Indent column; cbsa = Canadian "
                        "export where hierarchy is implied by code digit length; "
                        "taric = the canonical EU CSV from acquire/eu_taric.py; "
                        "dga = the Dominican Republic Arancel CSV (Spanish, "
                        "dash-prefix hierarchy).")
    p.add_argument("--lang", choices=tuple(_BASKET_RES), default="en",
                   help="Corpus language: drives basket-provision detection "
                        "('Los demás') and the exclusion-clause template.")
    p.add_argument("--max-depth", type=int, default=10,
                   help="Deepest legal code length for this jurisdiction (US/CA=10). "
                        "A leaf deeper than this fails the build.")
    args = p.parse_args()

    global CORPUS_LANG
    CORPUS_LANG = args.lang

    csv_path = Path(args.csv_path)
    chapters_path = Path(args.chapters_path)
    out_stem = Path(args.out_stem)
    out_stem.parent.mkdir(parents=True, exist_ok=True)

    loaders = {"usitc": load_rows, "cbsa": load_rows_cbsa,
               "taric": load_rows_taric, "dga": load_rows_dga}
    raw_rows, load_stats = loaders[args.source_format](csv_path)
    chapters_map = load_chapters(chapters_path)
    roots = build_tree(raw_rows)
    records, depth_hist, truncated = flatten_tree_to_records(
        roots, chapters_map, args.jurisdiction, args.revision
    )

    if not records:
        print("ERROR: no records produced", file=sys.stderr)
        return 2

    # ── Build-time assertions ────────────────────────────────────────
    # Jurisdiction depth is checked ONCE here rather than on every
    # classification. A leaf deeper than the schedule allows means the parser
    # or the source changed shape, and that must fail loudly at ingest.
    too_deep = [r for r in records if r["depth"] > args.max_depth]
    if too_deep:
        print(f"ERROR: {len(too_deep):,} leaf codes exceed --max-depth {args.max_depth}; "
              f"first: {too_deep[0]['code']}", file=sys.stderr)
        return 3

    dupes = len(records) - len({r["_id"] for r in records})
    if dupes:
        print(f"ERROR: {dupes:,} duplicate record ids", file=sys.stderr)
        return 4

    # ── Source-row conservation (the "no code is missed" invariant) ──────
    # Every coded source row (post-dedup) must appear as exactly one node in
    # the built tree, and the tree must invent nothing. Both directions are
    # impossible under a correct build_tree(), which is precisely why they are
    # the right assertions: free when everything works, and the only thing
    # that fires when it does not.
    nodes = collect_node_index(roots)
    missing = sorted(load_stats.coded_digits - set(nodes))
    if missing:
        print(f"ERROR: {len(missing):,} coded source row(s) never reached the "
              f"tree; first 20: {missing[:20]}", file=sys.stderr)
        return 5
    extra = sorted(set(nodes) - load_stats.coded_digits)
    if extra:
        print(f"ERROR: {len(extra):,} tree node(s) have no source row; "
              f"first 20: {extra[:20]}", file=sys.stderr)
        return 6

    # ── Official leaf cross-check (EU) ───────────────────────────────────
    # The source publishes its own leaf flags; our reconstructed tree must
    # agree EXACTLY. A mismatch means the hierarchy was rebuilt wrong even
    # though every code is present — the one failure mode L1 cannot see.
    if load_stats.official_leaf_digits is not None:
        ours = {d for d, has_children in nodes.items() if not has_children}
        official = load_stats.official_leaf_digits
        not_ours = sorted(official - ours)
        not_official = sorted(ours - official)
        if not_ours or not_official:
            print(f"ERROR: leaf set disagrees with the official IS_LEAF flags: "
                  f"{len(not_ours):,} official leaves are internal in our tree "
                  f"(first: {not_ours[:10]}); {len(not_official):,} of our "
                  f"leaves are official non-leaves (first: {not_official[:10]})",
                  file=sys.stderr)
            return 7
        print(f"  official leaf cross-check: {len(official):,} leaves agree")

    jsonl_path = out_stem.with_suffix(".jsonl")
    write_jsonl(records, jsonl_path)

    basket_count = sum(1 for r in records if r["is_basket"])
    manifest = {
        "record_count": len(records),
        "jurisdiction": args.jurisdiction,
        "revision": args.revision,
        "source_file": csv_path.name,
        "source_sha256": sha256_of(csv_path),
        "built_at": datetime.now(timezone.utc).isoformat(),
        "depth_histogram": {str(k): v for k, v in sorted(depth_hist.items())},
        "basket_count": basket_count,
        "max_chunk_text_chars": max(len(r["chunk_text"]) for r in records),
        "truncated_chunk_text": truncated["chunk"],
        "truncated_display_text": truncated["display"],
        "node_count": len(nodes),
        "source_raw_row_count": load_stats.raw_row_count,
        "source_coded_row_count": load_stats.coded_row_count,
        "source_condition_row_count": load_stats.condition_row_count,
        "dropped_duplicate_count": load_stats.dropped_duplicates,
        "dropped_uncoded_count": load_stats.dropped_uncoded,
    }
    manifest_path = out_stem.with_name(out_stem.name + ".manifest.json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    # Node index for the server-side code validator. Small (one bool per code)
    # and jurisdiction-agnostic, so it belongs beside the corpus rather than
    # being reconstructed from a 13.5 MB raw dataset at runtime.
    codes_path = out_stem.with_name(out_stem.name + ".codes.json")
    codes_path.write_text(json.dumps({
        "jurisdiction": args.jurisdiction,
        "revision": args.revision,
        "max_depth": args.max_depth,
        "node_count": len(nodes),
        "nodes": nodes,
    }, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Wrote node index ({len(nodes):,} codes) -> {codes_path}")

    # ── Per-revision coverage report ─────────────────────────────────────
    # Per-chapter accounting an operator (or the cross-revision diff) can
    # watch move. Orphan roots = roots whose code is longer than a heading —
    # CA has 353 (Ch.99 provisions with no heading row); a jump in that
    # number means the source changed shape.
    per_chapter: dict[str, dict] = {}
    for digits, has_children in nodes.items():
        ch = digits[:2]
        c = per_chapter.setdefault(ch, {"nodes": 0, "leaves": 0, "baskets": 0})
        c["nodes"] += 1
        if not has_children:
            c["leaves"] += 1
    for r in records:
        if r["is_basket"] and r["chapter"] in per_chapter:
            per_chapter[r["chapter"]]["baskets"] += 1
    orphan_roots = [
        (root.get("HTS Number") or "").strip()
        for root in roots
        if len(_digits_only(root.get("HTS Number") or "")) > 4
    ]
    chapters_no_codes = sorted(set(chapters_map) - set(per_chapter))
    codes_no_chapter_entry = sorted(set(per_chapter) - set(chapters_map))
    coverage = {
        "jurisdiction": args.jurisdiction,
        "revision": args.revision,
        "per_chapter": {k: per_chapter[k] for k in sorted(per_chapter)},
        "orphan_root_count": len(orphan_roots),
        "orphan_roots_sample": orphan_roots[:20],
        "chapters_in_config_with_no_codes": chapters_no_codes,
        "chapters_with_codes_but_no_config_entry": codes_no_chapter_entry,
    }
    coverage_path = out_stem.with_name(out_stem.name + ".coverage.json")
    coverage_path.write_text(json.dumps(coverage, indent=2) + "\n", encoding="utf-8")
    if codes_no_chapter_entry:
        # Records in these chapters get NO chapter prefix in chunk_text or
        # display_text — visible here rather than silently degraded.
        print(f"  WARNING: chapters with codes but no chapters-file entry: "
              f"{codes_no_chapter_entry}", file=sys.stderr)
    print(f"Wrote coverage report -> {coverage_path}")

    print(f"Wrote {len(records):,} leaf records -> {jsonl_path}")
    print(f"  depth histogram: {manifest['depth_histogram']}")
    print(f"  basket provisions: {basket_count:,} "
          f"({basket_count * 100 // len(records)}%)")
    print(f"  longest chunk_text: {manifest['max_chunk_text_chars']:,} chars")
    if truncated:
        # Never let a cap be silent — a truncated record still retrieves on its
        # breadcrumb prefix, but that is a fact the operator should see.
        print(f"  TRUNCATED: {truncated['chunk']} chunk_text, "
              f"{truncated['display']} display_text (see CHUNK_TEXT_CHAR_WARN)")
    print(f"Wrote manifest -> {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
