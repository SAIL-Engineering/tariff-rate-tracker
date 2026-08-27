#!/usr/bin/env python3
"""diff_revisions.py — cross-revision structural diff with gates.

The strongest "no code is missed" guard in the pipeline: compares the freshly
built node index (ALL codes, not just leaves — a tree that silently reparented
looks fine in a leaf count) and the corpus text against the previous revision
of the SAME jurisdiction, and fails the build when the change exceeds the
per-jurisdiction gates. Runs as the `verify` step BEFORE publish, so a bad
parse never reaches Pinecone or Supabase.

  diff_revisions.py --curr ca_2026_rev_2.codes.json \
                    --curr-jsonl ca_2026_rev_2.jsonl \
                    --jurisdiction CA --registry config/jurisdictions/ca_revisions.csv \
                    --max-removed-pct 2.0 --out ca_2026_rev_2.diff.json

Finding the previous revision, in priority order:
  1. --prev / --prev-jsonl, explicitly;
  2. the registry CSV: the newest revision before the current one whose
     <jur>_<rev>.codes.json exists locally (repo root, where builds land);
  3. none found -> warn LOUDLY and pass. First revision of a jurisdiction has
     nothing to diff against; that must not block it.

`leaf_to_internal` gets its own (tightest) gate: a code that was a valid
classification target and is now an internal node is exactly what the
condition-row bug produced (1,842 leaves lost), and it is invisible in raw
added/removed counts.

--allow-large-diff accepts a known restructure (e.g. HS 2028) — the gate's job
is to make you SAY it, not to stop you.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


def load_codes(path: Path) -> dict[str, bool]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return data["nodes"]


def load_display(path: Path) -> dict[str, str]:
    out = {}
    if not path or not path.is_file():
        return out
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            r = json.loads(line)
            digits = "".join(ch for ch in r.get("code", "") if ch.isdigit())
            out[digits] = r.get("display_text", "")
    return out


def find_previous(jurisdiction: str, curr_codes: Path, registry: Path | None):
    """Newest registry revision older than the current one with a local index."""
    if not registry or not registry.is_file():
        return None, None
    curr_name = curr_codes.name  # <jur>_<rev>.codes.json
    rows = list(csv.DictReader(registry.open(encoding="utf-8")))
    jl = jurisdiction.lower()
    candidates = []
    for r in rows:
        rev = r.get("revision", "")
        name = f"{jl}_{rev}.codes.json"
        if name == curr_name:
            continue
        p = curr_codes.parent / name
        if p.is_file():
            candidates.append((r.get("effective_date", ""), rev, p))
    if not candidates:
        return None, None
    candidates.sort()
    _, rev, path = candidates[-1]
    jsonl = path.with_name(f"{jl}_{rev}.jsonl")
    return path, (jsonl if jsonl.is_file() else None)


def fetch_prev_from_github(jurisdiction: str, curr_codes: Path,
                           registry: Path | None) -> Path | None:
    """Fetch the previous revision's shipped codes.json from the consumer repo.

    The ship step commits every revision's index to
    sail-gtx-prerelease:server/data/hts/, so on a fresh CI checkout — where no
    local prior artifacts exist — the last shipped index IS the previous
    corpus. Uses the same PAT the ship step already requires."""
    import base64
    import os
    import urllib.request

    token = os.environ.get("SAIL_GTX_REPO_PAT", "").strip()
    if not token or not registry or not registry.is_file():
        return None
    rows = list(csv.DictReader(registry.open(encoding="utf-8")))
    jl = jurisdiction.lower()
    curr_name = curr_codes.name
    candidates = sorted(
        (r.get("effective_date", ""), r.get("revision", ""))
        for r in rows
        if r.get("revision") and f"{jl}_{r['revision']}.codes.json" != curr_name)
    if not candidates:
        return None
    _, rev = candidates[-1]
    name = f"{jl}_{rev}.codes.json"
    owner_repo = os.environ.get("SAIL_GTX_REPO", "SAIL-Engineering/sail-gtx-prerelease")
    branch = os.environ.get("SAIL_GTX_PRODUCTION_BRANCH", "")
    url = (f"https://api.github.com/repos/{owner_repo}/contents/"
           f"server/data/hts/{name}" + (f"?ref={branch}" if branch else ""))
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "hts-automation-diff",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as fh:
            body = json.load(fh)
        content = base64.b64decode(body["content"])
    except Exception as e:  # noqa: BLE001 — any failure degrades to warn+pass
        print(f"WARNING: --fetch-prev could not retrieve {name}: {e}",
              file=sys.stderr)
        return None
    dest = curr_codes.parent / name
    dest.write_bytes(content)
    print(f"[diff] fetched previous index from {owner_repo}: {name}")
    return dest


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--curr", required=True, type=Path)
    p.add_argument("--curr-jsonl", type=Path)
    p.add_argument("--prev", type=Path)
    p.add_argument("--prev-jsonl", type=Path)
    p.add_argument("--jurisdiction", default="")
    p.add_argument("--registry", type=Path)
    p.add_argument("--max-removed-pct", type=float, default=2.0)
    p.add_argument("--max-added-pct", type=float, default=5.0)
    p.add_argument("--max-leaf-to-internal-pct", type=float, default=0.5)
    p.add_argument("--max-redescribed-pct", type=float, default=15.0)
    p.add_argument("--allow-large-diff", action="store_true")
    p.add_argument("--fetch-prev", action="store_true",
                   help="when the previous revision's codes.json is not on "
                        "local disk (fresh CI checkout), fetch it from the "
                        "sail-gtx-prerelease repo (server/data/hts/) via the "
                        "GitHub contents API using SAIL_GTX_REPO_PAT")
    p.add_argument("--out", type=Path)
    args = p.parse_args()

    prev, prev_jsonl = args.prev, args.prev_jsonl
    if not prev:
        prev, prev_jsonl = find_previous(args.jurisdiction, args.curr, args.registry)
    if not prev and args.fetch_prev:
        prev = fetch_prev_from_github(args.jurisdiction, args.curr, args.registry)
    if not prev:
        print("WARNING: no previous revision found to diff against — first "
              "revision for this jurisdiction, or prior artifacts are not on "
              "disk. PASSING WITHOUT A DIFF; the intra-build completeness "
              "assertions are the only structural guard for this run.",
              file=sys.stderr)
        if args.out:
            args.out.write_text(json.dumps({"skipped": "no_previous"}) + "\n")
        return 0

    curr_nodes = load_codes(args.curr)
    prev_nodes = load_codes(prev)
    print(f"[diff] prev {prev.name}: {len(prev_nodes):,} nodes | "
          f"curr {args.curr.name}: {len(curr_nodes):,} nodes")

    added = sorted(set(curr_nodes) - set(prev_nodes))
    removed = sorted(set(prev_nodes) - set(curr_nodes))
    common = set(curr_nodes) & set(prev_nodes)
    leaf_to_internal = sorted(d for d in common
                              if prev_nodes[d] is False and curr_nodes[d] is True)
    internal_to_leaf = sorted(d for d in common
                              if prev_nodes[d] is True and curr_nodes[d] is False)

    curr_disp = load_display(args.curr_jsonl)
    prev_disp = load_display(prev_jsonl) if prev_jsonl else {}
    redescribed = sorted(
        d for d in (set(curr_disp) & set(prev_disp))
        if curr_disp[d] != prev_disp[d]
    ) if prev_disp else []

    base = max(len(prev_nodes), 1)
    leaf_base = max(sum(1 for v in prev_nodes.values() if not v), 1)
    disp_base = max(len(prev_disp), 1)
    pcts = {
        "removed_pct": 100.0 * len(removed) / base,
        "added_pct": 100.0 * len(added) / base,
        "leaf_to_internal_pct": 100.0 * len(leaf_to_internal) / leaf_base,
        "redescribed_pct": (100.0 * len(redescribed) / disp_base) if prev_disp else 0.0,
    }
    report = {
        "jurisdiction": args.jurisdiction,
        "prev": prev.name, "curr": args.curr.name,
        "counts": {"added": len(added), "removed": len(removed),
                   "leaf_to_internal": len(leaf_to_internal),
                   "internal_to_leaf": len(internal_to_leaf),
                   "redescribed": len(redescribed)},
        "pcts": {k: round(v, 3) for k, v in pcts.items()},
        "added_sample": added[:50], "removed_sample": removed[:50],
        "leaf_to_internal_sample": leaf_to_internal[:50],
        "internal_to_leaf_sample": internal_to_leaf[:50],
        "redescribed_sample": redescribed[:50],
    }
    if args.out:
        args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"[diff] report -> {args.out}")

    for k, v in report["counts"].items():
        print(f"[diff]   {k:>18}: {v:,}")

    gates = [("removed_pct", args.max_removed_pct),
             ("added_pct", args.max_added_pct),
             ("leaf_to_internal_pct", args.max_leaf_to_internal_pct),
             ("redescribed_pct", args.max_redescribed_pct)]
    tripped = [(k, pcts[k], limit) for k, limit in gates if pcts[k] > limit]
    if tripped:
        for k, v, limit in tripped:
            print(f"[diff] GATE TRIPPED: {k} = {v:.2f}% > {limit}%", file=sys.stderr)
        if args.allow_large_diff:
            print("[diff] --allow-large-diff set: accepting anyway", file=sys.stderr)
            return 0
        print("[diff] failing the build; pass --allow-large-diff for a known "
              "restructure", file=sys.stderr)
        return 2
    print("[diff] within gates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
