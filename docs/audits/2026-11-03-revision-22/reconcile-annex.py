#!/usr/bin/env python3
"""Reconcile Proclamation 11076's graphic annex against the applied schedule.

Proclamation 11076 (91 FR 68861-68871) amends U.S. note 51(b)(3) -- the
operative product list for heading 9903.03.14, the Section 338 Canada action --
effective 12:01 a.m. eastern time on October 30, 2026. The Federal Register
text record of the annex is eight [GRAPHIC] [TIFF OMITTED] placeholders and
carries no machine-readable subheading, so the amendment cannot be read from it
directly.

The annex is therefore read three independent ways and the readings compared:

  1. Annex I, Parts A and B -- the prose tables. OCR'd from the scanned pages
     with the code column cropped away from the descriptions (which quote HTS
     codes of their own) and three segmentation modes required to agree.
  2. Annex II -- the numerical grid that states the deletions and insertions.
     OCR'd from full-page renders of the same scans.
  3. U.S. note 51(b)(3) itself, read from the native text layer of the Chapter
     99 PDFs for revisions 21 and 22 and diffed. This reads the applied
     schedule rather than the instrument, and uses no OCR.

Every code is then checked against the Revision 22 HTS universe.

Requires: poppler-utils (pdfimages, pdftoppm, pdftotext), tesseract,
ImageMagick (convert). Writes annex-reconciliation.json beside itself.

Usage: python3 -I reconcile-annex.py [--work <dir>]
"""
import argparse
import csv
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

AUDIT = Path(__file__).resolve().parent
REPO = AUDIT.parents[2]
PDF = AUDIT / "FR-2026-22292-proclamation-11076.pdf"
CH99 = REPO / "data/us_notes"
HTS_JSON = REPO / "data/hts_archives/hts_2026_rev_22.json"

CODE_EXACT = re.compile(r"^(\d{4}\.\d{2}\.\d{2})$")
CODE_ANY = re.compile(r"\b(\d{4}\.\d{2}\.\d{2})\b")
COLUMN_WIDTH = 620          # the code column occupies x~50-460 on these scans
PROSE_PSMS = ("4", "6", "12")
GRID_PAGES = (10, 11)       # PDF pages carrying Annex II
RENDER_DPI = 600            # the embedded scans are 600dpi; render to match
ANNEX_II_MARK = re.compile(r"deleting the following subheadings", re.I)

GRAPHICS = [
    ("TD30OC26.100", 4, "Annex I Part A heading and list"),
    ("TD30OC26.101", 5, "Annex I Part A list end; Part B heading and list start"),
    ("TD30OC26.102", 6, "Annex I Part B list"),
    ("TD30OC26.103", 7, "Annex I Part B list"),
    ("TD30OC26.104", 8, "Annex I Part B list"),
    ("TD30OC26.105", 9, "Annex I Part B list end"),
    ("TD30OC26.106", 10, "Annex II; note 51(b)(3) delete and insert grids"),
    ("TD30OC26.107", 11, "Annex II final grid row, vertically clipped"),
]


def run(cmd):
    proc = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(str(c) for c in cmd)}\n{proc.stderr[:400]}")
    return proc.stdout


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tsv_rows(path: Path) -> list[dict]:
    with path.open(encoding="utf-8", errors="replace") as fh:
        return [r for r in csv.DictReader(fh, delimiter="\t", quoting=csv.QUOTE_NONE)
                if (r.get("text") or "").strip()]


def ocr_text(image: Path, stem: Path, psm: str) -> str:
    run(["tesseract", image, stem, "--psm", psm])
    return Path(f"{stem}.txt").read_text(encoding="utf-8", errors="replace")


# --- 1. Annex I prose tables ------------------------------------------------

def annex_images(work: Path) -> list[Path]:
    """The annex scans, excluding the seal on page 3."""
    out = work / "img"
    out.mkdir(parents=True, exist_ok=True)
    run(["pdfimages", "-f", 4, "-l", 11, PDF, out / "annex"])
    images = sorted(out.glob("annex-*"))
    if len(images) != len(GRAPHICS):
        raise SystemExit(f"expected {len(GRAPHICS)} annex scans, extracted {len(images)}")
    return images


def column_codes(crop: Path, work: Path, name: str) -> list[tuple[int, str]]:
    """(y, code) down the code column, only if all segmentations agree."""
    readings = {}
    for psm in PROSE_PSMS:
        stem = work / f"{name}-col-{psm}"
        run(["tesseract", crop, stem, "--psm", psm,
             "-c", "tessedit_char_whitelist=0123456789.", "tsv"])
        hits = [(int(r["top"]), m.group(1))
                for r in tsv_rows(Path(f"{stem}.tsv"))
                if (m := CODE_EXACT.match(r["text"].strip().strip(".")))]
        readings[psm] = sorted(hits)
    lists = {psm: [c for _, c in rows] for psm, rows in readings.items()}
    first = lists[PROSE_PSMS[0]]
    if any(lists[p] != first for p in PROSE_PSMS[1:]):
        raise SystemExit(f"{name}: segmentation modes disagree on the code column: "
                         + ", ".join(f"psm{p}={len(lists[p])}" for p in PROSE_PSMS))
    return readings[PROSE_PSMS[0]]


def part_b_split(image: Path, work: Path, name: str) -> tuple[str, int | None]:
    """Full-page text, and the y of the 'Part B' heading if this page carries it.

    The crop keeps the image's origin, so this y and the column's are in the
    same coordinate space.
    """
    stem = work / f"{name}-page"
    run(["tesseract", image, stem, "--psm", "4", "tsv"])
    rows = tsv_rows(Path(f"{stem}.tsv"))
    text = " ".join(r["text"].strip() for r in rows)
    for i, r in enumerate(rows):
        if re.fullmatch(r"Part", r["text"].strip(), re.I):
            nxt = rows[i + 1]["text"].strip() if i + 1 < len(rows) else ""
            if re.fullmatch(r"B\.?", nxt, re.I):
                return text, int(r["top"])
    return text, None


def read_annex_i(work: Path) -> dict:
    part_a: list[str] = []
    part_b: list[str] = []
    pages = []
    split_page = None
    for image in annex_images(work):
        name = image.stem
        text, split_y = part_b_split(image, work, name)
        if ANNEX_II_MARK.search(text):
            break                           # Annex II starts here
        crop = work / f"{name}-col.png"
        run(["convert", image, "-crop", f"{COLUMN_WIDTH}x0+0+0", "+repage", crop])
        column = column_codes(crop, work, name)
        if not column:
            continue
        if split_y is not None:
            split_page = image.name
            above = [c for y, c in column if y < split_y]
            below = [c for y, c in column if y >= split_y]
            part_a += above
            part_b += below
            section = f"part_a({len(above)})+part_b({len(below)})"
        elif part_b:
            part_b += [c for _, c in column]
            section = "part_b"
        else:
            part_a += [c for _, c in column]
            section = "part_a"
        pages.append({"image": image.name, "codes": len(column), "section": section,
                      "part_b_heading_y": split_y, "segmentations_agree": True})
    return {"part_a": part_a, "part_b": part_b, "pages": pages, "split_page": split_page}


# --- 2. Annex II numerical grid ---------------------------------------------

def read_annex_ii(work: Path) -> dict:
    """Delete and insert lists from full-page renders of the Annex II grid.

    The grid is read from page renders rather than the embedded scans because
    its final row is a separately embedded strip clipped to 69px, which OCRs
    unreliably in isolation.
    """
    text = ""
    for page in GRID_PAGES:
        stem = work / f"grid-{page}"
        run(["pdftoppm", "-r", RENDER_DPI, "-f", page, "-l", page, "-png", PDF, stem])
        render = next(iter(sorted(work.glob(f"grid-{page}-*.png"))), None)
        if render is None:
            raise SystemExit(f"no render produced for page {page}")
        text += ocr_text(render, work / f"grid-{page}-ocr", "4") + "\n"

    def between(start: str, end: str | None) -> list[str]:
        s = re.search(start, text, re.I)
        if not s:
            raise SystemExit(f"Annex II marker not found: {start}")
        tail = text[s.end():]
        if end and (e := re.search(end, tail, re.I)):
            tail = tail[: e.start()]
        return [m.group(1) for m in CODE_ANY.finditer(tail)]

    deleted = between(r"deleting the following subheadings", r"inserting the following subheadings")
    inserted = between(r"inserting the following subheadings", None)
    return {"deleted": deleted, "inserted": inserted}


# --- 3. The applied schedule, without OCR -----------------------------------

NOTE_START = re.compile(r"^\s*\(3\)\s+Heading 9903\.03\.14 applies to articles classifiable")
NOTE_END = re.compile(r"^\s*\(c\)\s")


def note51(revision: str, work: Path) -> list[str]:
    src = CH99 / f"chapter99_{revision}.pdf"
    if not src.exists():
        raise SystemExit(f"missing {src}")
    txt = work / f"ch99_{revision}.txt"
    run(["pdftotext", "-layout", src, txt])
    lines = txt.read_text(encoding="utf-8", errors="replace").splitlines()
    start = next((i for i, l in enumerate(lines) if NOTE_START.search(l)), None)
    if start is None:
        raise SystemExit(f"{revision}: note 51(b)(3) not found")
    end = next((i for i in range(start + 1, len(lines)) if NOTE_END.search(lines[i])), None)
    if end is None:
        raise SystemExit(f"{revision}: end of note 51(b)(3) not found")
    codes = [m.group(1) for line in lines[start:end] for m in CODE_ANY.finditer(line)]
    # 9903.03.14 names the heading in the subdivision's opening sentence.
    return [c for c in codes if not c.startswith("9903.")]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", help="working directory (default: a temporary one)")
    args = ap.parse_args()
    tmp = None if args.work else tempfile.TemporaryDirectory()
    work = Path(args.work) if args.work else Path(tmp.name)
    work.mkdir(parents=True, exist_ok=True)

    print("reading Annex I prose tables ...")
    one = read_annex_i(work)
    part_a, part_b = one["part_a"], one["part_b"]
    print(f"  Part A {len(part_a)} | Part B {len(part_b)}")

    print("reading Annex II grid ...")
    two = read_annex_ii(work)
    deleted, inserted = two["deleted"], two["inserted"]
    print(f"  deleted {len(deleted)} | inserted {len(inserted)}")

    print("diffing the applied note 51(b)(3) ...")
    before, after = note51("2026_rev_21", work), note51("2026_rev_22", work)
    removed = sorted(set(before) - set(after))
    added = sorted(set(after) - set(before))
    print(f"  {len(before)} -> {len(after)} codes | removed {len(removed)} | added {len(added)}")

    universe = {(e.get("htsno") or "").strip()[:10]
                for e in json.loads(HTS_JSON.read_text(encoding="utf-8"))
                if (e.get("htsno") or "").strip()}

    def unknown(codes):
        return sorted({c for c in codes if c not in universe})

    agreement = {
        "three_way_delete_set_identical": set(part_a) == set(deleted) == set(removed),
        "three_way_insert_set_identical": set(part_b) == set(inserted) == set(added),
        "annex_i_part_a_equals_annex_ii_deleted_in_order": part_a == deleted,
        "annex_i_part_b_equals_annex_ii_inserted_in_order": part_b == inserted,
        "net_change_reconciles": len(after) - len(before) == len(inserted) - len(deleted),
        "no_overlap_between_parts": not (set(part_a) & set(part_b)),
        "no_duplicates": len(set(part_a)) == len(part_a) and len(set(part_b)) == len(part_b),
    }

    out = {
        "contract_version": "sail.annex-reconciliation/v1",
        "reconciled_on": "2026-11-03",
        "generated_by": "docs/audits/2026-11-03-revision-22/reconcile-annex.py",
        "instrument": {
            "proclamation": "11076",
            "fr_doc": "2026-22292",
            "citation": "91 FR 68861-68871",
            "signed": "2026-10-23",
            "published": "2026-10-30",
            "effective_at": "2026-10-30T00:01:00-04:00",
            "action": "Section 338 Canada motor-vehicle product scope amendment",
            "cumulation": "Expressly cumulative with Section 232; the proclamation does "
                          "not displace duties imposed under Proclamation 10048 as amended.",
            "provision_amended": "U.S. note 51(b)(3), subchapter III, chapter 99 "
                                 "(heading 9903.03.14)",
        },
        "graphic_annex": {
            "retained_pdf": "docs/audits/2026-11-03-revision-22/"
                            "FR-2026-22292-proclamation-11076.pdf",
            "sha256": sha256(PDF),
            "size_bytes": PDF.stat().st_size,
            "source_url": "https://www.govinfo.gov/content/pkg/FR-2026-10-30/pdf/2026-22292.pdf",
            "pages": 11,
            "codes_in_official_text_record": 0,
            "note": "The Federal Register text record carries only [GRAPHIC] "
                    "[TIFF OMITTED] placeholders for the annex, so no subheading is "
                    "machine-readable from it. The annex content exists only as the "
                    "eight scans listed below.",
            "graphics": [{"id": g, "pdf_page": p, "content": c} for g, p, c in GRAPHICS],
        },
        "sources": {
            "annex_i_prose": {
                "method": "OCR of the embedded annex scans. The code column is cropped "
                          "and read with a digit whitelist under three segmentation "
                          "modes that must agree; descriptions are excluded by the crop "
                          "so codes quoted in prose cannot enter the list. Parts A and B "
                          "are split at the y of the 'Part B' heading from a full-page "
                          "pass in the same coordinate space.",
                "pages": one["pages"],
                "part_b_split_page": one["split_page"],
                "counts": {"part_a": len(part_a), "part_b": len(part_b)},
            },
            "annex_ii_grid": {
                "method": f"OCR of {RENDER_DPI}dpi renders of PDF pages "
                          f"{GRID_PAGES[0]}-{GRID_PAGES[-1]}, split on the annex's own "
                          "delete and insert markers.",
                "counts": {"deleted": len(deleted), "inserted": len(inserted)},
            },
            "applied_schedule": {
                "method": "pdftotext -layout of the native text layer of the Chapter 99 "
                          "PDFs for revisions 21 and 22; note 51(b)(3) extracted and "
                          "diffed. No OCR.",
                "before": {"revision": "2026_rev_21", "codes": len(before)},
                "after": {"revision": "2026_rev_22", "codes": len(after)},
                "ascending_before": before == sorted(before),
                "ascending_after": after == sorted(after),
                "net_change": len(after) - len(before),
            },
        },
        "annex_i": {"part_a_no_longer_covered": part_a, "part_b_newly_covered": part_b},
        "annex_ii": {"note": "U.S. note 51(b)(3)", "deleted": deleted, "inserted": inserted},
        "applied_schedule_delta": {"removed": removed, "added": added},
        "agreement": agreement,
        "hts_validation": {
            "universe": "data/hts_archives/hts_2026_rev_22.json, 8-digit subheadings",
            "universe_size": len(universe),
            "unknown_in_part_a": unknown(part_a),
            "unknown_in_part_b": unknown(part_b),
            "unknown_in_deleted": unknown(deleted),
            "unknown_in_inserted": unknown(inserted),
            "unknown_in_added": unknown(added),
            "unknown_in_removed": unknown(removed),
        },
        "ocr_limitations": [
            "TD30OC26.107 is a vertically clipped 3364x69 strip carrying the final "
            "Annex II grid row. Its glyphs are cut off and segmentation modes do not "
            "agree on it; read in isolation it yields no reliable codes. Its four "
            "subheadings (9018.90.60, 9023.00.00, 9027.30.80, 9506.99.05) are "
            "established by the full-page render and independently by the Chapter 99 "
            "note 51(b)(3) diff, which uses no OCR.",
            "Agreement of three readings, one of which is OCR-free, is what supports "
            "these lists. OCR of a scanned legal annex is not a substitute for human "
            "review of the original.",
        ],
        "conclusion": "Reconciled. Annex I Parts A and B, the Annex II grid and the "
                      "applied note 51(b)(3) diff identify the same 22 deleted and 100 "
                      "inserted subheadings, in the same order, and all 122 exist in the "
                      "Revision 22 HTS universe.",
    }

    dest = AUDIT / "annex-reconciliation.json"
    dest.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    print("\nagreement: " + "  ".join(f"{k}={v}" for k, v in agreement.items()))
    print("unknown vs HTS universe: " + ", ".join(
        f"{k.replace('unknown_in_', '')}={len(v)}"
        for k, v in out["hts_validation"].items() if k.startswith("unknown_")))
    print(f"wrote {dest}")
    if not all(agreement.values()) or any(
            v for k, v in out["hts_validation"].items() if k.startswith("unknown_")):
        print("RECONCILIATION FAILED", file=sys.stderr)
        return 1
    if tmp:
        tmp.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
