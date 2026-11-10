"""Manual acquisition: the operator supplies the file; we glob and parse.

This is the Dominican Republic path (no public machine-readable source) and
the universal escape hatch when a scraper breaks: any jurisdiction can be
forced onto it with `refresh.py --acquire-adapter manual [--source path]`.

Revision facts come from the filename (<prefix>_<year>_rev_<n>.<ext>), the CLI
(--effective-date / --revision), or a sidecar `<file>.meta.json` with keys
{"effective_date": ..., "effective_date_label": ...}.

A jurisdiction whose editions are NOT numbered that way declares them instead,
in `acquire.manual_revision`:

    "manual_revision": {"rev_id": "2022", "year": 2022, "rev_num": 1,
                        "source": "sg_tariff_2022.csv",
                        "effective_date": "2022-01-01",
                        "effective_date_label": "STCCED 2022 edition"}

Singapore publishes one STCCED edition (2022), Malaysia one Customs Duties
Order (pdk2025) and Vietnam a dated workbook (2026_0405): none has a revision
NUMBER, and deriving one from the filename would invent a fact the source does
not state. Before this, every one of the three failed at
"--revision must look like 2026_rev_2" and could not be published at all.

Declared facts are used only where the filename convention cannot speak. --source,
--revision and --effective-date still override, and a jurisdiction without the
block behaves exactly as before.
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import re
from pathlib import Path

from . import AcquireResult

_NAME_RE = re.compile(r"^(?P<prefix>.+)_(?P<year>\d{4})_rev_(?P<num>\d+)$")


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _label_for(date_iso: str) -> str:
    d = _dt.date.fromisoformat(date_iso)
    return f"{d.strftime('%B')} {d.day}, {d.year}"


def resolve(spec: dict, args) -> AcquireResult:
    acquire = spec.get("acquire") or {}
    opts = acquire.get("options") or {}
    declared = acquire.get("manual_revision") or {}
    src = getattr(args, "source", None)
    if not src and declared.get("source"):
        # An edition named by the spec rather than by the _rev_<n> convention.
        directory = Path(opts.get("dir") or acquire.get("manual_dir") or ".")
        candidate = directory / declared["source"]
        if not candidate.is_file():
            raise SystemExit(
                f"ERROR: {candidate} is missing. It is the source "
                f"{spec.get('code', '?')}'s spec declares "
                f"(acquire.manual_revision.source); run the parser in "
                f"{opts.get('parser', 'the jurisdiction parser')} to write it.")
        src = candidate
    if not src:
        directory = Path(opts.get("dir") or acquire.get("manual_dir") or ".")
        prefix = opts.get("prefix") or acquire.get("manual_prefix") or ""
        candidates = sorted(directory.glob(f"{prefix}_*_rev_*.*"),
                            key=lambda p: p.stat().st_mtime, reverse=True)
        # Only canonical stems qualify: language-variant CSVs
        # (…_rev_901.de.csv) and sidecars sit beside the base file and must
        # never be picked as "the" source.
        stem_re = re.compile(rf"^{re.escape(prefix)}_\d{{4}}_rev_\d+$")
        candidates = [c for c in candidates
                      if not c.name.endswith(".meta.json")
                      and stem_re.match(c.stem)]
        if not candidates:
            raise SystemExit(
                f"ERROR: no source found in {directory}/ named {prefix}_<year>_rev_<n>.*\n"
                f"       Drop the file there or pass --source.")
        src = candidates[0]
    src = Path(src)
    if not src.is_file():
        raise SystemExit(f"ERROR: source {src} does not exist")

    rev_id = None
    if getattr(args, "revision", None):
        m = re.match(r"^(\d{4})_rev_(\d+)$", args.revision)
        if m:
            year, num = int(m.group(1)), int(m.group(2))
        elif declared and args.revision == declared.get("rev_id"):
            # The spec's own id, passed explicitly. Accept it rather than
            # demanding a shape this jurisdiction does not use.
            rev_id, year, num = (declared["rev_id"], int(declared["year"]),
                                 declared["rev_num"])
        else:
            expected = (f"{declared['rev_id']!r} or " if declared.get("rev_id") else "")
            raise SystemExit(
                f"ERROR: --revision must be {expected}<year>_rev_<n>, "
                f"got {args.revision!r}")
    elif declared.get("rev_id"):
        rev_id, year, num = (declared["rev_id"], int(declared["year"]),
                             declared["rev_num"])
    else:
        m = _NAME_RE.match(src.stem)
        if not m:
            raise SystemExit(
                f"ERROR: cannot derive a revision from {src.name!r} — "
                f"expected <prefix>_<year>_rev_<n>, or pass --revision.")
        year, num = int(m.group("year")), int(m.group("num"))

    meta = {}
    sidecar = src.with_name(src.name + ".meta.json")
    if sidecar.exists():
        meta = json.loads(sidecar.read_text(encoding="utf-8"))
    eff = (getattr(args, "effective_date", None) or meta.get("effective_date")
           or declared.get("effective_date"))
    if not eff:
        raise SystemExit(
            "ERROR: no effective date. Pass --effective-date YYYY-MM-DD, add "
            f"{sidecar.name} with {{\"effective_date\": ...}}, or declare it in "
            "the spec's acquire.manual_revision.")
    label = (meta.get("effective_date_label") or declared.get("effective_date_label")
             or _label_for(eff))

    return AcquireResult(
        rev_id=rev_id or f"{year}_rev_{num}", year=year, rev_num=num,
        effective_date=eff, effective_date_label=label,
        source_csv=str(src), source_sha256=_sha256(src),
        acquired_at=_dt.datetime.now(_dt.timezone.utc).isoformat(),
    )


def fetch(spec: dict, args) -> AcquireResult:
    # Nothing to fetch — the human already did. resolve() is the whole step.
    return resolve(spec, args)
