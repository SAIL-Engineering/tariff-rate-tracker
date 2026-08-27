#!/usr/bin/env python3
"""Download the latest CBSA Canadian Customs Tariff Microsoft Access archive
and export every ACCDB table to CSV with mdb-tools.

Default behavior:
  1. Fetch the CBSA Customs Tariff menu page for the requested year.
  2. Cross-check the other official-language page (English/French) by default.
  3. Detect every TYYYY / TYYYY-N revision and effective date.
  4. Select the newest revision.
  5. Download the requested-language Microsoft Access ZIP.
  6. Safely extract all .accdb files.
  7. Run `mdb-tables -1` and `mdb-export` for every table.
  8. Write metadata.json and <year>/latest.json manifests.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import re
import shutil
import subprocess
import sys
import time
import zipfile
from dataclasses import asdict, dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Iterable
from urllib.parse import urljoin, urlparse

import requests
from bs4 import BeautifulSoup, Tag
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


LOG = logging.getLogger("cbsa-tariff")

REVISION_RE = re.compile(r"\bT(?P<year>\d{4})(?:-(?P<revision>\d+))?\b", re.IGNORECASE)
DATE_RE = re.compile(r"\b(?P<date>\d{4}-\d{2}-\d{2})\b")
ACCESS_TEXT_RE = re.compile(r"Microsoft\s+Access", re.IGNORECASE)
HEADING_NAMES = {f"h{i}" for i in range(1, 7)}
INVALID_FILENAME_RE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


@dataclass(frozen=True)
class RevisionInfo:
    revision: str
    revision_number: int
    effective_date: str
    access_url: str
    page_url: str
    language: str
    access_url_derived: bool = False

    @property
    def effective_date_obj(self) -> date:
        return date.fromisoformat(self.effective_date)


@dataclass(frozen=True)
class ExportedTable:
    table_name: str
    csv_file: str
    accdb_file: str


def make_session() -> requests.Session:
    retry = Retry(
        total=4,
        connect=4,
        read=4,
        status=4,
        backoff_factor=0.8,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset({"GET", "HEAD"}),
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry)
    session = requests.Session()
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    session.headers.update(
        {
            "User-Agent": (
                "Mozilla/5.0 (compatible; CBSA-Tariff-Downloader/1.0; "
                "+https://www.cbsa-asfc.gc.ca/)"
            ),
            # CBSA pages can be CDN-cached; ask intermediaries to revalidate.
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "Accept": "text/html,application/xhtml+xml,application/zip,*/*;q=0.8",
        }
    )
    return session


def normalize_space(value: str) -> str:
    return " ".join(value.replace("\xa0", " ").split())


def menu_url(year: int, language: str) -> str:
    return (
        f"https://www.cbsa-asfc.gc.ca/trade-commerce/tariff-tarif/"
        f"{year}/menu-{language}.html"
    )


def fetch_html(session: requests.Session, url: str, timeout: int) -> str:
    LOG.info("Fetching CBSA page: %s", url)
    response = session.get(url, timeout=timeout)
    response.raise_for_status()
    response.encoding = response.apparent_encoding or response.encoding
    return response.text


def _find_access_link_for_heading(heading: Tag, page_url: str) -> str | None:
    """Find the Microsoft Access archive belonging to one revision heading.

    Search only until the next heading that itself looks like a TYYYY revision,
    so a link from a later revision cannot be accidentally associated with the
    current block.
    """
    fallback_zip: str | None = None

    for element in heading.find_all_next():
        if element is heading:
            continue
        if not isinstance(element, Tag):
            continue

        if element.name in HEADING_NAMES:
            text = normalize_space(element.get_text(" ", strip=True))
            if REVISION_RE.search(text) and DATE_RE.search(text):
                break

        if element.name != "a" or not element.get("href"):
            continue

        href = urljoin(page_url, element["href"])
        link_text = normalize_space(element.get_text(" ", strip=True))
        path = urlparse(href).path.lower()

        if ACCESS_TEXT_RE.search(link_text):
            return href

        # Conservative fallback for slight CBSA label changes.
        if path.endswith(".zip") and "/01-99/" in path:
            fallback_zip = fallback_zip or href

    return fallback_zip


def parse_revisions(html: str, page_url: str, language: str) -> list[RevisionInfo]:
    soup = BeautifulSoup(html, "html.parser")
    revisions: list[RevisionInfo] = []

    for heading in soup.find_all(list(HEADING_NAMES)):
        heading_text = normalize_space(heading.get_text(" ", strip=True))
        rev_match = REVISION_RE.search(heading_text)
        date_match = DATE_RE.search(heading_text)
        if not rev_match or not date_match:
            continue

        year = int(rev_match.group("year"))
        revision_number = int(rev_match.group("revision") or 0)
        revision = f"T{year}" + (f"-{revision_number}" if revision_number else "")
        effective_date = date_match.group("date")
        access_url = _find_access_link_for_heading(heading, page_url)

        if not access_url:
            LOG.warning(
                "Found %s (%s) but no Microsoft Access ZIP link in its block on %s",
                revision,
                effective_date,
                page_url,
            )
            continue

        revisions.append(
            RevisionInfo(
                revision=revision,
                revision_number=revision_number,
                effective_date=effective_date,
                access_url=access_url,
                page_url=page_url,
                language=language,
                access_url_derived=False,
            )
        )

    return revisions


def discover_language(
    session: requests.Session,
    year: int,
    language: str,
    timeout: int,
    page_url_override: str | None = None,
) -> list[RevisionInfo]:
    page_url = page_url_override or menu_url(year, language)
    html = fetch_html(session, page_url, timeout)
    revisions = parse_revisions(html, page_url, language)
    if not revisions:
        raise RuntimeError(
            f"No CBSA tariff revisions with Microsoft Access links were found on {page_url}. "
            "The page structure may have changed."
        )
    return revisions


def revision_sort_key(item: RevisionInfo) -> tuple[date, int]:
    # Effective date is the strongest signal for a newer schedule. Revision
    # number breaks ties if CBSA ever publishes multiple revisions for one date.
    return (item.effective_date_obj, item.revision_number)


def derive_language_url(access_url: str, target_language: str) -> str:
    """Convert a CBSA archive URL between -eng.zip and -fra.zip when needed."""
    if target_language == "eng":
        return re.sub(r"-fra(?=\.zip(?:$|\?))", "-eng", access_url, flags=re.IGNORECASE)
    return re.sub(r"-eng(?=\.zip(?:$|\?))", "-fra", access_url, flags=re.IGNORECASE)


def choose_latest_revision(
    revisions_by_language: dict[str, list[RevisionInfo]],
    requested_language: str,
) -> tuple[RevisionInfo, dict[str, list[RevisionInfo]]]:
    all_revisions = [r for values in revisions_by_language.values() for r in values]
    if not all_revisions:
        raise RuntimeError("No tariff revisions were discovered.")

    latest_identity = max(all_revisions, key=revision_sort_key)

    # Prefer the exact requested-language entry for the latest revision/date.
    for candidate in revisions_by_language.get(requested_language, []):
        if (
            candidate.revision == latest_identity.revision
            and candidate.effective_date == latest_identity.effective_date
        ):
            return candidate, revisions_by_language

    # If one language page was updated before the other, retain the authoritative
    # revision/date from the newer page and derive the parallel CBSA language URL.
    LOG.warning(
        "Latest revision %s (%s) was not present on the %s page. "
        "Using the other official-language page for discovery and deriving the %s archive URL.",
        latest_identity.revision,
        latest_identity.effective_date,
        requested_language,
        requested_language,
    )
    return (
        RevisionInfo(
            revision=latest_identity.revision,
            revision_number=latest_identity.revision_number,
            effective_date=latest_identity.effective_date,
            access_url=derive_language_url(latest_identity.access_url, requested_language),
            page_url=latest_identity.page_url,
            language=requested_language,
            access_url_derived=True,
        ),
        revisions_by_language,
    )


def archive_filename(url: str, revision: RevisionInfo) -> str:
    name = Path(urlparse(url).path).name
    if name.lower().endswith(".zip"):
        return name
    language = revision.language
    year = revision.revision[1:5]
    suffix = f"-{revision.revision_number}" if revision.revision_number else ""
    return f"01-99-{year}{suffix}-{language}.zip"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_archive(
    session: requests.Session,
    url: str,
    destination: Path,
    timeout: int,
    force: bool,
) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)

    if destination.exists() and not force:
        if zipfile.is_zipfile(destination):
            LOG.info("Archive already exists; reusing: %s", destination)
            return destination
        LOG.warning("Existing file is not a valid ZIP; re-downloading: %s", destination)

    temp_path = destination.with_suffix(destination.suffix + ".part")
    temp_path.unlink(missing_ok=True)

    LOG.info("Downloading Microsoft Access archive: %s", url)
    with session.get(url, stream=True, timeout=timeout) as response:
        response.raise_for_status()
        with temp_path.open("wb") as handle:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    handle.write(chunk)

    if not zipfile.is_zipfile(temp_path):
        temp_path.unlink(missing_ok=True)
        raise RuntimeError(
            f"Downloaded file from {url} is not a valid ZIP archive. "
            "CBSA may have changed the download format or URL."
        )

    temp_path.replace(destination)
    return destination


def safe_extract_zip(zip_path: Path, destination: Path, force: bool) -> list[Path]:
    if force and destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True, exist_ok=True)
    destination_resolved = destination.resolve()

    with zipfile.ZipFile(zip_path) as archive:
        for member in archive.infolist():
            target = (destination / member.filename).resolve()
            if target != destination_resolved and destination_resolved not in target.parents:
                raise RuntimeError(f"Unsafe path in ZIP archive: {member.filename!r}")
        archive.extractall(destination)

    accdb_files = sorted(destination.rglob("*.accdb"))
    if not accdb_files:
        raise RuntimeError(f"No .accdb files were found after extracting {zip_path}")

    LOG.info("Extracted %d ACCDB file(s)", len(accdb_files))
    return accdb_files


def require_mdbtools() -> tuple[str, str]:
    mdb_tables = shutil.which("mdb-tables")
    mdb_export = shutil.which("mdb-export")
    missing = [name for name, value in (("mdb-tables", mdb_tables), ("mdb-export", mdb_export)) if not value]
    if missing:
        raise RuntimeError(
            "Missing required mdb-tools command(s): "
            + ", ".join(missing)
            + ". On Debian/Ubuntu run: sudo apt install mdbtools"
        )
    return mdb_tables, mdb_export


def list_tables(accdb_file: Path, mdb_tables: str) -> list[str]:
    result = subprocess.run(
        [mdb_tables, "-1", str(accdb_file)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"mdb-tables failed for {accdb_file}: {result.stderr.strip() or 'unknown error'}"
        )

    tables = [line.rstrip("\r\n") for line in result.stdout.splitlines() if line.strip()]
    LOG.info("Found %d table(s) in %s", len(tables), accdb_file.name)
    return tables


def portable_csv_name(table_name: str, used: set[str]) -> str:
    base = INVALID_FILENAME_RE.sub("_", table_name).strip().rstrip(".")
    base = base or "table"
    candidate = f"{base}.csv"
    if candidate.casefold() not in used:
        used.add(candidate.casefold())
        return candidate

    short_hash = hashlib.sha1(table_name.encode("utf-8")).hexdigest()[:8]
    candidate = f"{base}__{short_hash}.csv"
    used.add(candidate.casefold())
    return candidate


def export_accdb_tables(
    accdb_file: Path,
    csv_dir: Path,
    mdb_tables: str,
    mdb_export: str,
    force: bool,
) -> list[ExportedTable]:
    csv_dir.mkdir(parents=True, exist_ok=True)
    tables = list_tables(accdb_file, mdb_tables)
    used_names: set[str] = set()
    exports: list[ExportedTable] = []

    for index, table in enumerate(tables, start=1):
        csv_name = portable_csv_name(table, used_names)
        csv_path = csv_dir / csv_name

        if csv_path.exists() and not force:
            LOG.info("[%d/%d] CSV already exists; reusing: %s", index, len(tables), csv_path.name)
        else:
            LOG.info("[%d/%d] Exporting table %r -> %s", index, len(tables), table, csv_path.name)
            temp_path = csv_path.with_suffix(csv_path.suffix + ".part")
            temp_path.unlink(missing_ok=True)
            with temp_path.open("wb") as output:
                result = subprocess.run(
                    [mdb_export, str(accdb_file), table],
                    check=False,
                    stdout=output,
                    stderr=subprocess.PIPE,
                )
            if result.returncode != 0:
                temp_path.unlink(missing_ok=True)
                stderr = result.stderr.decode("utf-8", errors="replace").strip()
                raise RuntimeError(
                    f"mdb-export failed for table {table!r} in {accdb_file}: "
                    f"{stderr or 'unknown error'}"
                )
            temp_path.replace(csv_path)

        exports.append(
            ExportedTable(
                table_name=table,
                csv_file=str(csv_path),
                accdb_file=str(accdb_file),
            )
        )

    return exports


def revision_to_json(item: RevisionInfo) -> dict[str, object]:
    return asdict(item)


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".part")
    temp.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temp.replace(path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Detect and download the latest Canadian CBSA Customs Tariff Microsoft Access archive, "
            "then export every ACCDB table to CSV using mdb-tools."
        )
    )
    parser.add_argument(
        "--year",
        type=int,
        default=date.today().year,
        help="Tariff year to inspect (default: current year).",
    )
    parser.add_argument(
        "--language",
        choices=("eng", "fra"),
        default="eng",
        help="Language of the archive to download (default: eng).",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("canada_tariff"),
        help="Root output directory (default: ./canada_tariff).",
    )
    parser.add_argument(
        "--page-url",
        help="Override the primary CBSA menu URL. Mainly useful for testing or a future site move.",
    )
    parser.add_argument(
        "--no-language-cross-check",
        action="store_true",
        help="Do not cross-check the other CBSA official-language tariff page.",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Only detect and print the latest revision/date/link; do not download or export.",
    )
    parser.add_argument(
        "--skip-csv",
        action="store_true",
        help="Download and extract the ACCDB but do not invoke mdb-tools or create CSV files.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-download/re-extract/re-export even when output files already exist.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="HTTP timeout in seconds (default: 60).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable debug logging.",
    )
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    session = make_session()
    revisions_by_language: dict[str, list[RevisionInfo]] = {}

    try:
        revisions_by_language[args.language] = discover_language(
            session=session,
            year=args.year,
            language=args.language,
            timeout=args.timeout,
            page_url_override=args.page_url,
        )

        if not args.no_language_cross_check and args.page_url is None:
            other_language = "fra" if args.language == "eng" else "eng"
            try:
                revisions_by_language[other_language] = discover_language(
                    session=session,
                    year=args.year,
                    language=other_language,
                    timeout=args.timeout,
                )
            except Exception as exc:  # Cross-check failure should not block the primary page.
                LOG.warning("Could not cross-check %s page: %s", other_language, exc)

        latest, revisions_by_language = choose_latest_revision(
            revisions_by_language,
            requested_language=args.language,
        )

        print(f"Latest revision: {latest.revision}")
        print(f"Effective date: {latest.effective_date}")
        print(f"Microsoft Access ZIP: {latest.access_url}")

        if args.check_only:
            return 0

        revision_dir = (
            args.output_dir
            / str(args.year)
            / f"{latest.revision}__effective-{latest.effective_date}"
        )
        source_dir = revision_dir / "source"
        extracted_dir = revision_dir / "access"
        csv_root = revision_dir / "csv"

        zip_name = archive_filename(latest.access_url, latest)
        zip_path = source_dir / zip_name
        download_archive(
            session=session,
            url=latest.access_url,
            destination=zip_path,
            timeout=args.timeout,
            force=args.force,
        )
        accdb_files = safe_extract_zip(zip_path, extracted_dir, force=args.force)

        exports: list[ExportedTable] = []
        if not args.skip_csv:
            mdb_tables, mdb_export = require_mdbtools()
            multiple_accdb = len(accdb_files) > 1
            for accdb_file in accdb_files:
                csv_dir = csv_root / accdb_file.stem if multiple_accdb else csv_root
                exports.extend(
                    export_accdb_tables(
                        accdb_file=accdb_file,
                        csv_dir=csv_dir,
                        mdb_tables=mdb_tables,
                        mdb_export=mdb_export,
                        force=args.force,
                    )
                )

        metadata = {
            "detected_at_utc": datetime.now(timezone.utc).isoformat(),
            "tariff_year": args.year,
            "selected": revision_to_json(latest),
            "discovered_revisions": {
                language: [revision_to_json(item) for item in sorted(items, key=revision_sort_key, reverse=True)]
                for language, items in revisions_by_language.items()
            },
            "download": {
                "zip_file": str(zip_path),
                "zip_sha256": sha256_file(zip_path),
                "accdb_files": [str(path) for path in accdb_files],
            },
            "csv_export": {
                "enabled": not args.skip_csv,
                "table_count": len(exports),
                "tables": [asdict(item) for item in exports],
            },
        }

        write_json(revision_dir / "metadata.json", metadata)
        write_json(args.output_dir / str(args.year) / "latest.json", metadata)

        print(f"Output directory: {revision_dir}")
        print(f"ACCDB files: {len(accdb_files)}")
        if args.skip_csv:
            print("CSV export: skipped")
        else:
            print(f"CSV tables exported: {len(exports)}")
        print(f"Manifest: {revision_dir / 'metadata.json'}")
        return 0

    except KeyboardInterrupt:
        LOG.error("Interrupted")
        return 130
    except Exception as exc:
        LOG.error("%s", exc)
        if args.verbose:
            LOG.exception("Detailed traceback")
        return 1


if __name__ == "__main__":
    sys.exit(main())
