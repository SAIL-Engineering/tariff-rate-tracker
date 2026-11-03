#!/usr/bin/env python3
"""Render and OCR the graphic annex pages of a Federal Register proclamation.

Several Section 338 and Section 232 proclamations publish their annexes as
scans: the Federal Register text record carries only [GRAPHIC] [TIFF OMITTED]
placeholders, so the operative subheading lists are not machine-readable from
it. The evidence tree therefore retains per-page OCR alongside the source PDF,
and `section338_sources.py` parses those retained pages.

This produces those pages reproducibly. Settings were chosen by reproducing an
already-retained page (2026-18839 page 4) from its source PDF: at 600dpi with
tesseract's default segmentation the output matches except for two instances of
"nesoi"/"neso1" inside a product description. Descriptions cannot widen an
operative table -- only the code column is read as membership -- so that
residual is immaterial.

Writes <out-dir>/<id>-<page>.txt and prints the sha256 of each, in the form the
evidence manifest records.

Usage:
  python3 -I ocr_legal_annex.py <pdf> <first-page> <last-page> [--out-dir DIR]
                                [--id ID] [--dpi N] [--manifest-json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DPI = 600
PSM = "3"


def run(cmd: list) -> None:
    proc = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(str(c) for c in cmd)}\n{proc.stderr[:400]}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def ocr_page(pdf: Path, page: int, work: Path, dpi: int) -> str:
    stem = work / f"page-{page:02d}"
    run(["pdftoppm", "-r", dpi, "-f", page, "-l", page, "-png", pdf, stem])
    renders = sorted(work.glob(f"page-{page:02d}-*.png"))
    if len(renders) != 1:
        raise SystemExit(f"expected one render for page {page}, got {len(renders)}")
    run(["tesseract", renders[0], stem, "--psm", PSM])
    return Path(f"{stem}.txt").read_text(encoding="utf-8", errors="replace")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf", type=Path)
    ap.add_argument("first", type=int)
    ap.add_argument("last", type=int)
    ap.add_argument("--out-dir", type=Path,
                    default=ROOT / "resources/legal_evidence/section338/ocr")
    ap.add_argument("--id", help="document id used in filenames (default: PDF stem)")
    ap.add_argument("--dpi", type=int, default=DPI)
    ap.add_argument("--manifest-json", action="store_true",
                    help="print the manifest 'ocr' array instead of a table")
    args = ap.parse_args()

    doc_id = args.id or args.pdf.stem
    args.out_dir.mkdir(parents=True, exist_ok=True)
    entries = []
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for page in range(args.first, args.last + 1):
            text = ocr_page(args.pdf, page, work, args.dpi)
            dest = args.out_dir / f"{doc_id}-{page:02d}.txt"
            dest.write_text(text, encoding="utf-8")
            entries.append({"path": str(dest.relative_to(ROOT)),
                            "sha256": sha256(dest.read_bytes())})
            if not args.manifest_json:
                print(f"  page {page:>2}  {len(text.splitlines()):>3} lines  "
                      f"{entries[-1]['sha256'][:16]}...  {dest.name}", file=sys.stderr)

    if args.manifest_json:
        print(json.dumps(entries, indent=2))
    else:
        print(f"\nsource {args.pdf.name}  sha256 {sha256(args.pdf.read_bytes())}",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
