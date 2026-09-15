#!/usr/bin/env python3
"""sync_usitc_archive.py — pull what the USITC HTS archive listing knows about
each revision into the repo's registries.

The archive list (https://www.usitc.gov/harmonized_tariff_information/hts/archive/list)
is the one place that carries, per revision:

  * the Modification Source(s): titles, Federal Register citations and direct
    FR document links. The Reasoning & sources panel cites them via
    resources/tpc_policy_revision_map_usitc_archive_enriched.csv ->
    scripts/emit_revision_sources.R.
  * the ACTUAL download filenames. Several 2019-2022 editions were published
    under one-off names (htsdata_3.csv, hts_2021_revision_basic_1_csv.csv, ...),
    so the convention-built URLs in src/02_download_hts.R and
    scripts/hts_automation/usitc_native.py 404 for them.

Commands (each accepts --dry-run):

  sources    Fill the link columns of config/revision_dates.csv rows that have
             none, then append registry revisions missing from the enriched
             source map. Curated cells are never overwritten, and
             policy_family is left for a human to assign (rows without one are
             listed).
  file-urls  Rewrite config/hts_archive_file_urls.csv: every (revision, format)
             whose convention URL does not serve but whose archive link does.
  upgrade-links
             Replace Federal Register SEARCH links in both registries with the
             archive's direct link for the same citation. A link is swapped
             only on an exact citation match; anything else stays a search
             link and is listed.
  all        sources + file-urls.

After `sources`, regenerate the bundles with `Rscript scripts/emit_revision_sources.R`.

The stock urllib User-Agent is deliberate: the www.usitc.gov WAF 403s
browser-like and custom UA strings but allows tool defaults.
"""
from __future__ import annotations

import argparse
import csv
import html
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urljoin, urlparse

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "hts_automation"))
import usitc_native as u                                  # noqa: E402

REPO_ROOT = HERE.parent
ARCHIVE_URL = "https://www.usitc.gov/harmonized_tariff_information/hts/archive/list"
SITE = "https://www.usitc.gov"
REV_DATES = u.CSV_PATH
SOURCE_MAP = REPO_ROOT / "resources" / "tpc_policy_revision_map_usitc_archive_enriched.csv"
FILE_URLS = u.FILE_URLS_PATH
FILE_URL_FIELDS = ["revision", "format", "url", "note"]

LINK_COLS = ["usitc_archive_page_url", "modification_source_titles",
             "modification_source_citations", "federal_register_or_source_links",
             "source_commentary"]
COMMENTARY = ("Archive-driven from USITC HTS archive Modification Source(s). "
              "Use links to validate legal authority, effective dates, and "
              "Chapter 99 text.")


def _na(value: str | None) -> bool:
    return value in (None, "", "NA")


# ─── fetch + parse ───────────────────────────────────────────────────

def _get(url: str, timeout: int = 60) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def _text(fragment: str) -> str:
    """HTML fragment -> plain text with the registry's ASCII punctuation."""
    t = re.sub(r"<svg.*?</svg>", " ", fragment, flags=re.S)
    t = html.unescape(re.sub(r"<[^>]+>", " ", t))
    for fancy, plain in (("\u2019", "'"), ("\u2018", "'"), ("\u201c", '"'),
                         ("\u201d", '"'), ("\u200b", "")):
        t = t.replace(fancy, plain)
    return re.sub(r"\s+", " ", t).strip()


def revision_ids(title: str) -> list[str]:
    """Archive heading -> registry ids.

    '2026 HTS Revision 19 (September 15, 2026)'      -> ['2026_rev_19']
    '2021 HTSA Basic Revision 3 (April 27, 2021)'     -> ['2021_rev_3']
    '2022 HTSA Basic and Revision 1 (Feb 15, 2022)'   -> ['2022_basic', '2022_rev_1']
    '2019 HTSA Basic Edition (February 15, 2019)'     -> ['2019_basic']
    preliminary / supplement editions                 -> []
    """
    m = re.match(r"^(\d{4}) HTSA? (.*?)\s*\([^()]*\)\s*$", title)
    if not m:
        return []
    year, body = m.groups()
    if body == "Basic and Revision 1":
        return [f"{year}_basic", f"{year}_rev_1"]
    rev = re.fullmatch(r"(?:Basic )?Revision (\d+)", body)
    if rev:
        return [f"{year}_rev_{rev.group(1)}"]
    if re.fullmatch(r"Basic(?: Edition)?", body):
        return [f"{year}_basic"]
    return []


def parse_page(page_html: str) -> list[dict]:
    """One archive list page -> entries (newest first, as listed)."""
    starts = [m.start() for m in
              re.finditer(r"views-field-field-hts-arch-published-date", page_html)]
    entries = []
    for i, start in enumerate(starts):
        chunk = page_html[start: starts[i + 1] if i + 1 < len(starts) else len(page_html)]
        heading = re.search(r'<span class="field-content">(.*?)</span>', chunk, re.S)
        title = _text(heading.group(1)) if heading else ""

        files: dict[str, str] = {}
        downloads = re.search(r"File Downloads:</strong>(.*?)</span>", chunk, re.S)
        if downloads:
            for href, label in re.findall(r'<a href="([^"]+)"[^>]*>(.*?)</a>',
                                          downloads.group(1), re.S):
                files[_text(label).lower()] = urljoin(SITE, html.unescape(href))

        sources = []
        mods = re.search(r"Modification Source\(s\):(.*)", chunk, re.S)
        if mods:
            for item in re.findall(r'<div class="margin-y-1">(.*?)</div>',
                                   mods.group(1), re.S):
                links = re.findall(r'<a href="([^"]+)"[^>]*>(.*?)</a>', item, re.S)
                if not links:
                    sources.append({"title": _text(item), "citation": "", "url": ""})
                    continue
                href, label = links[-1]
                # "<title> (<a href=...>91 Fed. Reg. 58331</a>)"
                name = _text(item[: item.rfind("<a ")]).rstrip("( ").strip()
                # 'Reg . 55989' typo; a stray '(' when one item holds two links
                citation = re.sub(r"\s+\.", ".", _text(label)).lstrip("( ")
                sources.append({"title": name, "citation": citation,
                                "url": urljoin(SITE, html.unescape(href))})

        entries.append({"title": title, "ids": revision_ids(title),
                        "files": files, "sources": sources})
    return entries


def fetch_archive(delay: float = 1.0) -> dict[str, dict]:
    """Walk every archive page -> {revision_id: entry}."""
    by_revision: dict[str, dict] = {}
    page = 0
    while True:
        url = ARCHIVE_URL if page == 0 else f"{ARCHIVE_URL}?page={page}"
        entries = parse_page(_get(url))
        if not entries:
            break
        for entry in entries:
            entry["page_url"] = url
            for rid in entry["ids"]:
                by_revision.setdefault(rid, entry)
        page += 1
        if page > 50:
            sys.exit("archive pagination did not terminate after 50 pages")
        time.sleep(delay)
    print(f"USITC archive: {page} page(s), {len(by_revision)} revision ids")
    return by_revision


# ─── sources ─────────────────────────────────────────────────────────

def cmd_sources(archive: dict[str, dict], dry_run: bool) -> None:
    rows = u._read_rows(REV_DATES)
    filled, unlisted = [], []
    for r in rows:
        if not all(_na(r.get(c)) for c in LINK_COLS):
            continue                                  # curated — leave as is
        entry = archive.get(r["revision"])
        if not entry or not entry["sources"]:
            unlisted.append(r["revision"])
            continue
        srcs = entry["sources"]
        r["usitc_archive_page_url"] = entry["page_url"]
        r["modification_source_titles"] = " | ".join(s["title"] for s in srcs)
        r["modification_source_citations"] = " | ".join(s["citation"] for s in srcs)
        r["federal_register_or_source_links"] = " | ".join(s["url"] for s in srcs)
        r["source_commentary"] = COMMENTARY
        filled.append(r["revision"])

    with SOURCE_MAP.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        map_fields = list(reader.fieldnames or [])
        map_rows = list(reader)
    by_id = {r["revision"]: r for r in map_rows}
    appended = []
    for r in rows:
        if r["revision"] in by_id or _na(r.get("modification_source_titles")):
            continue
        new = {f: r.get(f, "NA") for f in map_fields}
        # emit_revision_sources.R reads this column as the policy family.
        new["tpc_policy_revision"] = r.get("policy_family") or "NA"
        new["needs_review"] = "NA"
        by_id[r["revision"]] = new
        appended.append(r["revision"])
    registry_order = [r["revision"] for r in rows]
    merged = ([by_id[rid] for rid in registry_order if rid in by_id]
              + [r for r in map_rows if r["revision"] not in set(registry_order)])

    print(f"\nrevision_dates.csv: filled link columns for {len(filled)} row(s): "
          f"{', '.join(filled) or '-'}")
    if unlisted:
        print(f"  no archive Modification Sources for: {', '.join(unlisted)}")
    print(f"source map: appended {len(appended)} revision(s): {', '.join(appended) or '-'}")
    no_family = [r["revision"] for r in rows
                 if r["revision"] in appended and _na(r.get("policy_family"))]
    if no_family:
        print(f"  WARNING: no policy_family (assign in revision_dates.csv, then "
              f"re-run): {', '.join(no_family)}")
    if dry_run:
        print("[DRY RUN] nothing written")
        return
    if filled:
        u._write_rows(REV_DATES, rows)
    if appended:
        _write_csv(SOURCE_MAP, map_fields, merged)


def _write_csv(path: Path, fields: list[str], rows: list[dict]) -> None:
    """Same dialect as usitc_native._write_rows: LF, minimal quoting, NA."""
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow({k: (r.get(k) if r.get(k) not in (None, "") else "NA")
                        for k in fields})


# ─── upgrade-links ───────────────────────────────────────────────────

def _norm_citation(citation: str | None) -> str:
    """Federal Register cites -> 'fr <volume> <page>', tolerating the archive's
    typos ('91 Fed. Reg . 55989', '90. Fed. Reg. 43737', '(90 Fed. Reg. 14705');
    anything else (e.g. '484(f)') -> lower-cased, whitespace-collapsed."""
    c = re.sub(r"\s+", " ", citation or "").strip()
    fr = re.search(r"(\d+)\s*\.?\s*(?:Fed\s*\.?\s*Reg\s*\.?|FR)\s*(\d+)", c, re.I)
    return f"fr {fr.group(1)} {fr.group(2)}" if fr else c.lower()


def upgrade_search_links(row: dict, entry: dict | None) -> int:
    """Swap each FR search link in `row` for the archive's direct link to the
    same citation (citations and links are parallel ' | ' lists). Returns the
    number swapped; the cell is rewritten only when something changed."""
    cell = row.get("federal_register_or_source_links")
    if not entry or _na(cell) or "/documents/search" not in cell:
        return 0
    direct: dict[str, str] = {}
    for src in entry["sources"]:
        # A bare site root (e.g. https://www.whitehouse.gov/) cites nothing;
        # the search link it would replace is the better pointer.
        if (src["url"] and src["citation"] and "/documents/search" not in src["url"]
                and urlparse(src["url"]).path not in ("", "/")):
            direct.setdefault(_norm_citation(src["citation"]), src["url"])
    links = [x.strip() for x in cell.split(" | ")]
    cites = [x.strip() for x in (row.get("modification_source_citations") or "").split(" | ")]
    swapped = 0
    for k, link in enumerate(links):
        if "/documents/search" not in link or k >= len(cites):
            continue
        url = direct.get(_norm_citation(cites[k]))
        if url:
            links[k] = url
            swapped += 1
    if swapped:
        row["federal_register_or_source_links"] = " | ".join(links)
    return swapped


def cmd_upgrade_links(archive: dict[str, dict], dry_run: bool) -> None:
    rows = u._read_rows(REV_DATES)
    with SOURCE_MAP.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        map_fields = list(reader.fieldnames or [])
        map_rows = list(reader)
    for label, table in (("revision_dates.csv", rows), ("source map", map_rows)):
        swapped, left = 0, []
        for r in table:
            swapped += upgrade_search_links(r, archive.get(r["revision"]))
            links = (r.get("federal_register_or_source_links") or "").split(" | ")
            cites = (r.get("modification_source_citations") or "").split(" | ")
            for k, link in enumerate(links):
                if "/documents/search" in link:
                    archive_cites = [s["citation"] for s in
                                     (archive.get(r["revision"]) or {}).get("sources", [])]
                    left.append(f"{r['revision']}: {cites[k] if k < len(cites) else '?'}"
                                f"  (archive: {' | '.join(archive_cites) or 'no sources'})")
        print(f"\n{label}: swapped {swapped} search link(s) for direct links; "
              f"{len(left)} left as search links")
        for line in left:
            print(f"  {line}")
    if dry_run:
        print("[DRY RUN] nothing written")
        return
    u._write_rows(REV_DATES, rows)
    _write_csv(SOURCE_MAP, map_fields, map_rows)


# ─── file-urls ───────────────────────────────────────────────────────

def _serves(url: str, fmt: str) -> bool:
    """True when `url` returns the start of a real JSON / HTS CSV file."""
    req = urllib.request.Request(url, headers={"Range": "bytes=0-299"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            ctype = resp.headers.get("Content-Type", "")
            head = resp.read(300).lstrip(b"\xef\xbb\xbf")
    except (urllib.error.HTTPError, OSError):
        return False
    if "text/html" in ctype:
        return False
    return head[:1] in (b"{", b"[") if fmt == "json" else b"HTS Number" in head


def _filename(url: str) -> str:
    return url.rsplit("/", 1)[-1]


def cmd_file_urls(archive: dict[str, dict], dry_run: bool) -> None:
    registry = [r["revision"] for r in u._read_rows(REV_DATES)]
    out, broken = [], []
    for rid in registry:
        entry = archive.get(rid)
        if not entry:
            continue
        for fmt in ("json", "csv"):
            href = entry["files"].get(fmt)
            convention = u.convention_download_url(rid, fmt)
            if not href or _filename(href) == _filename(convention):
                continue
            if _serves(convention, fmt):              # unlisted but valid
                continue
            if not _serves(href, fmt):
                broken.append(f"{rid} {fmt}: {href}")
                continue
            out.append({"revision": rid, "format": fmt, "url": href, "note": ""})
            time.sleep(0.5)

    shared: dict[str, list[str]] = {}
    for row in out:
        shared.setdefault(row["url"], []).append(row["revision"])
    for row in out:
        notes = []
        others = [r for r in shared[row["url"]] if r != row["revision"]]
        if others:
            notes.append(f"same file as {', '.join(others)}")
        named = re.search(r"revision_(\d+)", _filename(row["url"]))
        own = re.search(r"_rev_(\d+)$", row["revision"])
        if named and own and named.group(1) != own.group(1):
            notes.append(f"archive links this edition to a file named for "
                         f"revision {named.group(1)}")
        row["note"] = "; ".join(notes)

    print(f"\nhts_archive_file_urls.csv: {len(out)} override(s) "
          f"({sum(r['format'] == 'csv' for r in out)} csv, "
          f"{sum(r['format'] == 'json' for r in out)} json)")
    for line in broken:
        print(f"  WARNING: archive link does not serve either: {line}")
    if dry_run:
        for row in out:
            print(f"  {row['revision']:12} {row['format']:4} {row['url']}"
                  + (f"  [{row['note']}]" if row["note"] else ""))
        print("[DRY RUN] nothing written")
        return
    _write_csv(FILE_URLS, FILE_URL_FIELDS, out)
    print(f"  wrote {FILE_URLS.relative_to(REPO_ROOT)}")


# ─── CLI ─────────────────────────────────────────────────────────────

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("sources", "file-urls", "upgrade-links", "all"):
        sub.add_parser(name).add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    archive = fetch_archive()
    if args.cmd in ("sources", "all"):
        cmd_sources(archive, args.dry_run)
    if args.cmd in ("file-urls", "all"):
        cmd_file_urls(archive, args.dry_run)
    if args.cmd == "upgrade-links":
        cmd_upgrade_links(archive, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
