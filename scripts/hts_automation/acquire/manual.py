"""Manual acquisition: the operator supplies the file; we glob and parse.

This is the Dominican Republic path (no public machine-readable source) and
the universal escape hatch when a scraper breaks: any jurisdiction can be
forced onto it with `refresh.py --acquire-adapter manual [--source path]`.

Revision facts come from the filename (<prefix>_<year>_rev_<n>.<ext>), the CLI
(--effective-date / --revision), or a sidecar `<file>.meta.json` with keys
{"effective_date": ..., "effective_date_label": ...}.
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
    opts = (spec.get("acquire") or {}).get("options") or {}
    src = getattr(args, "source", None)
    if not src:
        directory = Path(opts.get("dir")
                         or (spec.get("acquire") or {}).get("manual_dir")
                         or ".")
        prefix = opts.get("prefix") or (spec.get("acquire") or {}).get("manual_prefix") or ""
        candidates = sorted(directory.glob(f"{prefix}_*_rev_*.*"),
                            key=lambda p: p.stat().st_mtime, reverse=True)
        candidates = [c for c in candidates if not c.name.endswith(".meta.json")]
        if not candidates:
            raise SystemExit(
                f"ERROR: no source found in {directory}/ named {prefix}_<year>_rev_<n>.*\n"
                f"       Drop the file there or pass --source.")
        src = candidates[0]
    src = Path(src)
    if not src.is_file():
        raise SystemExit(f"ERROR: source {src} does not exist")

    if getattr(args, "revision", None):
        m = re.match(r"^(\d{4})_rev_(\d+)$", args.revision)
        if not m:
            raise SystemExit(f"ERROR: --revision must look like 2026_rev_2, got {args.revision!r}")
        year, num = int(m.group(1)), int(m.group(2))
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
    eff = getattr(args, "effective_date", None) or meta.get("effective_date")
    if not eff:
        raise SystemExit(
            "ERROR: no effective date. Pass --effective-date YYYY-MM-DD or add "
            f"{sidecar.name} with {{\"effective_date\": ...}}.")
    label = meta.get("effective_date_label") or _label_for(eff)

    return AcquireResult(
        rev_id=f"{year}_rev_{num}", year=year, rev_num=num,
        effective_date=eff, effective_date_label=label,
        source_csv=str(src), source_sha256=_sha256(src),
        acquired_at=_dt.datetime.now(_dt.timezone.utc).isoformat(),
    )


def fetch(spec: dict, args) -> AcquireResult:
    # Nothing to fetch — the human already did. resolve() is the whole step.
    return resolve(spec, args)
