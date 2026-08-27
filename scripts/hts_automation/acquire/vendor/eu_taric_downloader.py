#!/usr/bin/env python3
"""Download the latest monthly EU TARIC database extraction from CIRCABC.

The script discovers the newest CIRCABC release folder that contains the
required TARIC workbooks, downloads the workbooks, validates them, converts
all workbook sheets to UTF-8 CSV, and writes audit-friendly metadata.

Required workbooks:
  * Duties Import 01-99.xlsx
  * Duties Export 01-99.xlsx
  * Nomenclature EN.xlsx
  * Nomenclature FR.xlsx
  * Nomenclature DE.xlsx

Default source:
  European Commission CIRCABC TARIC library
  Group: 0e5f18c2-4b2f-42e9-aed4-dfe50ae1263b
  Root folder: 566dd333-1deb-4235-982a-4fdeaf3657c1

Discovery deliberately uses CIRCABC's REST API rather than scraping the
Angular UI.  Downloads use CIRCABC's /rest/download/{node_id} endpoint.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import logging
import math
import os
import re
import shutil
import sys
import unicodedata
import zipfile
from collections import deque
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import requests
# VENDOR-PATCH: import lazily so --check-only / --list-releases work without
# openpyxl installed; only the CSV export needs it.
try:
    from openpyxl import load_workbook
except ImportError:          # pragma: no cover
    load_workbook = None
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


LOG = logging.getLogger("eu-taric")

CIRCABC_HOST = "https://circabc.europa.eu"
CIRCABC_API_BASE = f"{CIRCABC_HOST}/service/circabc"
CIRCABC_DOWNLOAD_BASE = f"{CIRCABC_HOST}/rest/download"

DEFAULT_GROUP_ID = "0e5f18c2-4b2f-42e9-aed4-dfe50ae1263b"
DEFAULT_ROOT_ID = "566dd333-1deb-4235-982a-4fdeaf3657c1"

# These are the five artifacts the user identified as the minimum TARIC
# schedule/duty dataset required for this workflow.
TARGET_FILES: dict[str, str] = {
    "duties_import": "Duties Import 01-99.xlsx",
    "duties_export": "Duties Export 01-99.xlsx",
    "nomenclature_en": "Nomenclature EN.xlsx",
    "nomenclature_fr": "Nomenclature FR.xlsx",
    "nomenclature_de": "Nomenclature DE.xlsx",
    # VENDOR-PATCH: the corpus pipeline additionally needs the official leaf
    # flags (IS_LEAF); the duty pipeline needs origin groups and the measure
    # exclusions (6,553 active exclusions change which origins a duty applies
    # to). Conditions/additional-code names/geo descriptions enrich the duty
    # output and are OPTIONAL — fetched when present, warned when absent.
    "declarable_codes": "Declarable codes.xlsx",
    "geo_composition": "Geographical areas composition.xlsx",
    "measure_exclusions": "Measure exclusions.xlsx",
    "measure_conditions": "Measure conditions.xlsx",
    "addcodes_descriptions": "Additional codes descriptions.xlsx",
    "geo_description": "Geographical areas description.xlsx",
}

# VENDOR-PATCH: a release folder is COMPLETE when every REQUIRED file is
# present; optional files ride along. The original all-or-nothing rule made
# one missing enrichment workbook silently select LAST month's snapshot.
REQUIRED_FILES = frozenset({
    "duties_import", "duties_export", "nomenclature_en", "nomenclature_fr",
    "nomenclature_de", "declarable_codes", "geo_composition",
    "measure_exclusions",
})

# CIRCABC node types are Alfresco QNames such as
# {http://www.alfresco.org/model/content/1.0}folder / ...}content.
FOLDER_TYPE_RE = re.compile(r"(?:\}|:)folder$", re.IGNORECASE)
CONTENT_TYPE_RE = re.compile(r"(?:\}|:)content$", re.IGNORECASE)
INVALID_FILENAME_RE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
WHITESPACE_RE = re.compile(r"\s+")

# Month names in the languages relevant to the supplied nomenclature files,
# plus common English abbreviations.  Accents are removed before matching.
_MONTHS_RAW = {
    1: ["january", "jan", "janvier", "janv", "januar"],
    2: ["february", "feb", "february", "fevrier", "fevr", "februar"],
    3: ["march", "mar", "mars", "marz", "maerz", "marz"],
    4: ["april", "apr", "avril"],
    5: ["may", "mai"],
    6: ["june", "jun", "juin", "juni"],
    7: ["july", "jul", "juillet", "juil", "juli"],
    8: ["august", "aug", "aout", "aou", "august"],
    9: ["september", "sep", "sept", "septembre"],
    10: ["october", "oct", "octobre", "oktober", "okt"],
    11: ["november", "nov", "novembre"],
    12: ["december", "dec", "decembre", "dezember", "dez"],
}


@dataclass
class ReleaseCandidate:
    folder_id: str
    folder_name: str
    path_names: list[str]
    files: dict[str, dict[str, Any]]
    release_month: str | None
    snapshot_date: str | None
    date_source: str
    latest_modified: str | None
    latest_modified_dt: datetime | None = field(repr=False, default=None)

    def serializable(self) -> dict[str, Any]:
        data = asdict(self)
        data.pop("latest_modified_dt", None)
        data["file_names"] = {
            logical: node.get("name") for logical, node in self.files.items()
        }
        data.pop("files", None)
        return data


@dataclass
class CsvExport:
    workbook_logical_name: str
    workbook_file: str
    sheet_name: str
    csv_file: str
    rows: int
    columns: int


class TaricError(RuntimeError):
    """Raised for a controlled TARIC discovery/download/conversion failure."""


def strip_accents(value: str) -> str:
    decomposed = unicodedata.normalize("NFKD", value)
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))


def normalize_text(value: str) -> str:
    value = value.replace("\xa0", " ")
    value = strip_accents(value).casefold()
    return WHITESPACE_RE.sub(" ", value).strip()


def normalize_filename(value: str) -> str:
    value = normalize_text(value)
    # Be tolerant to minor spacing changes around the 01-99 range.
    value = re.sub(r"\s*-\s*", "-", value)
    return value


def safe_filename(value: str, fallback: str = "file") -> str:
    value = INVALID_FILENAME_RE.sub("_", value).strip().rstrip(".")
    value = WHITESPACE_RE.sub(" ", value)
    return value or fallback


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def make_session() -> requests.Session:
    retry = Retry(
        total=5,
        connect=5,
        read=5,
        status=5,
        backoff_factor=1.0,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset({"GET", "HEAD"}),
        respect_retry_after_header=True,
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry)
    session = requests.Session()
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    session.headers.update(
        {
            "User-Agent": (
                "Mozilla/5.0 (compatible; EU-TARIC-Downloader/1.0; "
                "+https://circabc.europa.eu/)"
            ),
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        }
    )
    return session


def circabc_folder_ui_url(group_id: str, node_id: str) -> str:
    return f"{CIRCABC_HOST}/ui/group/{group_id}/library/{node_id}"


def circabc_file_ui_url(group_id: str, node_id: str) -> str:
    return f"{circabc_folder_ui_url(group_id, node_id)}/details"


def circabc_download_url(node_id: str) -> str:
    return f"{CIRCABC_DOWNLOAD_BASE}/{node_id}"


def fetch_children(
    session: requests.Session,
    folder_id: str,
    timeout: int,
    *,
    folder_only: bool = False,
    file_only: bool = False,
) -> list[dict[str, Any]]:
    """Return all visible children for a public CIRCABC folder.

    CIRCABC supports limit=0 for "all".  page=0 follows the backend's
    zero-based paging implementation and is irrelevant when limit=0.
    """
    url = f"{CIRCABC_API_BASE}/spaces/{folder_id}/children"
    params: dict[str, str | int] = {
        "guest": "true",
        "limit": 0,
        "page": 0,
        "order": "modified_DESC",
    }
    if folder_only:
        params["folderOnly"] = "true"
    if file_only:
        params["fileOnly"] = "true"

    LOG.debug("CIRCABC children: %s", folder_id)
    response = session.get(
        url,
        params=params,
        headers={"Accept": "application/json"},
        timeout=timeout,
    )

    if response.status_code in (401, 403):
        raise TaricError(
            f"CIRCABC denied guest access to folder {folder_id} "
            f"(HTTP {response.status_code}). Confirm the library is still public."
        )
    response.raise_for_status()

    try:
        payload = response.json()
    except ValueError as exc:
        preview = response.text[:300].replace("\n", " ")
        raise TaricError(
            f"CIRCABC returned non-JSON content for folder {folder_id}: {preview!r}"
        ) from exc

    if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
        raise TaricError(
            f"Unexpected CIRCABC children response for folder {folder_id}. "
            "Expected an object containing a 'data' array."
        )

    return [node for node in payload["data"] if isinstance(node, dict)]


def is_folder(node: dict[str, Any]) -> bool:
    node_type = str(node.get("type") or "")
    if FOLDER_TYPE_RE.search(node_type):
        return True
    # Folder links are uncommon here but can appear in CIRCABC.  A node that
    # advertises subfolders and has no file MIME type is safe to traverse.
    props = node.get("properties") or {}
    return bool(node.get("hasSubFolders")) and not props.get("mimetype")


def is_content(node: dict[str, Any]) -> bool:
    node_type = str(node.get("type") or "")
    if CONTENT_TYPE_RE.search(node_type):
        return True
    props = node.get("properties") or {}
    return bool(props.get("mimetype") or props.get("size"))


def node_display_name(node: dict[str, Any]) -> str:
    name = str(node.get("name") or "").strip()
    if name:
        return name
    title = node.get("title")
    if isinstance(title, dict):
        for preferred in ("en", "fr", "de"):
            if title.get(preferred):
                return str(title[preferred]).strip()
        for value in title.values():
            if value:
                return str(value).strip()
    return str(node.get("id") or "unnamed")


def parse_datetime_loose(value: Any) -> datetime | None:
    if not value:
        return None
    raw = str(value).strip()
    if not raw:
        return None

    # Common ISO-8601 variants, including Java's +0000 offset form.
    candidates = [raw, raw.replace("Z", "+00:00")]
    if re.search(r"[+-]\d{4}$", raw):
        candidates.append(raw[:-5] + raw[-5:-2] + ":" + raw[-2:])

    for candidate in candidates:
        try:
            dt = datetime.fromisoformat(candidate)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except ValueError:
            pass

    for fmt in (
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d",
        "%d/%m/%Y %H:%M:%S",
        "%d/%m/%Y",
        "%a %b %d %H:%M:%S %Z %Y",
    ):
        try:
            dt = datetime.strptime(raw, fmt)
            return dt.replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None


def node_modified(node: dict[str, Any]) -> tuple[str | None, datetime | None]:
    props = node.get("properties")
    if not isinstance(props, dict):
        return None, None
    for key in ("modified", "created"):
        raw = props.get(key)
        parsed = parse_datetime_loose(raw)
        if raw:
            return str(raw), parsed
    return None, None


def match_required_files(children: Iterable[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    expected = {
        logical: normalize_filename(filename) for logical, filename in TARGET_FILES.items()
    }
    matches: dict[str, list[dict[str, Any]]] = {key: [] for key in TARGET_FILES}

    for node in children:
        if not is_content(node):
            continue
        name = normalize_filename(node_display_name(node))
        for logical, expected_name in expected.items():
            if name == expected_name:
                matches[logical].append(node)
                break

    selected: dict[str, dict[str, Any]] = {}
    for logical, nodes in matches.items():
        if not nodes:
            continue
        # If a folder somehow contains duplicate visible nodes with the same
        # filename, prefer the most recently modified one deterministically.
        nodes.sort(
            key=lambda n: node_modified(n)[1] or datetime.min.replace(tzinfo=timezone.utc),
            reverse=True,
        )
        selected[logical] = nodes[0]
        if len(nodes) > 1:
            LOG.warning(
                "Folder contains %d nodes named %s; using newest node %s",
                len(nodes),
                TARGET_FILES[logical],
                nodes[0].get("id"),
            )

    return selected


def _year_from_text(text: str) -> int | None:
    years = [int(y) for y in re.findall(r"(?<!\d)(20\d{2})(?!\d)", text)]
    if not years:
        return None
    # Path text is ordered from root to leaf, so the last year is usually the
    # release-specific one if more than one happens to occur.
    return years[-1]


def infer_release_date_from_path(path_names: list[str]) -> tuple[str | None, str | None, str]:
    """Infer release month/date from folder names without assuming one format.

    Returns (YYYY-MM, YYYY-MM-DD-or-None, source).
    """
    text = normalize_text(" / ".join(path_names))

    # YYYY-MM-DD / YYYY_MM_DD / YYYY.MM.DD / YYYY MM DD
    match = re.search(
        r"(?<!\d)(20\d{2})\s*[-_./ ]\s*(0?[1-9]|1[0-2])\s*[-_./ ]\s*([0-2]?\d|3[01])(?!\d)",
        text,
    )
    if match:
        year, month, day = map(int, match.groups())
        try:
            exact = date(year, month, day)
            return f"{year:04d}-{month:02d}", exact.isoformat(), "folder_path_exact_date"
        except ValueError:
            pass

    # DD-MM-YYYY. Only accept when the middle component is a valid month.
    match = re.search(
        r"(?<!\d)([0-2]?\d|3[01])\s*[-_./ ]\s*(0?[1-9]|1[0-2])\s*[-_./ ]\s*(20\d{2})(?!\d)",
        text,
    )
    if match:
        day, month, year = map(int, match.groups())
        try:
            exact = date(year, month, day)
            return f"{year:04d}-{month:02d}", exact.isoformat(), "folder_path_exact_date"
        except ValueError:
            pass

    # YYYY-MM / YYYY_MM / YYYY.MM, including path combinations such as
    # "2026 / 08" where year and month are separate folders.
    match = re.search(
        r"(?<!\d)(20\d{2})\s*[-_./ ]+\s*(0?[1-9]|1[0-2])(?!\d)", text
    )
    if match:
        year, month = map(int, match.groups())
        return f"{year:04d}-{month:02d}", None, "folder_path_month"

    # MM-YYYY.
    match = re.search(
        r"(?<!\d)(0?[1-9]|1[0-2])\s*[-_./ ]+\s*(20\d{2})(?!\d)", text
    )
    if match:
        month, year = map(int, match.groups())
        return f"{year:04d}-{month:02d}", None, "folder_path_month"

    # Compact YYYYMM.
    match = re.search(r"(?<!\d)(20\d{2})(0[1-9]|1[0-2])(?!\d)", text)
    if match:
        year, month = map(int, match.groups())
        return f"{year:04d}-{month:02d}", None, "folder_path_month"

    # Month-name folders, including e.g. root / 2026 / August.
    year = _year_from_text(text)
    if year:
        for month, names in _MONTHS_RAW.items():
            for name in names:
                normalized_name = normalize_text(name)
                if re.search(rf"(?<![a-z]){re.escape(normalized_name)}(?![a-z])", text):
                    return f"{year:04d}-{month:02d}", None, "folder_path_month_name"

    return None, None, "unknown"


def candidate_from_folder(
    folder_id: str,
    folder_name: str,
    path_names: list[str],
    files: dict[str, dict[str, Any]],
) -> ReleaseCandidate:
    release_month, snapshot_date, date_source = infer_release_date_from_path(path_names)

    latest_raw: str | None = None
    latest_dt: datetime | None = None
    for node in files.values():
        raw, dt = node_modified(node)
        if dt is not None and (latest_dt is None or dt > latest_dt):
            latest_dt = dt
            latest_raw = raw
        elif latest_dt is None and raw and latest_raw is None:
            latest_raw = raw

    # If no release month is encoded in the folder path, the file modification
    # timestamp is a practical discovery fallback, but it is explicitly labeled
    # as such in metadata rather than presented as a legal effective date.
    if release_month is None and latest_dt is not None:
        release_month = f"{latest_dt.year:04d}-{latest_dt.month:02d}"
        date_source = "file_modified_fallback"

    return ReleaseCandidate(
        folder_id=folder_id,
        folder_name=folder_name,
        path_names=path_names,
        files=files,
        release_month=release_month,
        snapshot_date=snapshot_date,
        date_source=date_source,
        latest_modified=latest_raw,
        latest_modified_dt=latest_dt,
    )


def path_has_other_explicit_year(path_names: list[str], requested_year: int) -> bool:
    """Return True only when a path component is exactly another YYYY year.

    This is intentionally conservative; it avoids pruning folders merely
    because a description contains an unrelated four-digit number.
    """
    for component in path_names:
        normalized = normalize_text(component)
        if re.fullmatch(r"20\d{2}", normalized):
            return int(normalized) != requested_year
    return False


def discover_release_candidates(
    session: requests.Session,
    root_id: str,
    timeout: int,
    max_depth: int,
    max_folders: int,
    year: int | None,
) -> tuple[list[ReleaseCandidate], list[tuple[str, list[str]]]]:
    """Breadth-first scan for folders containing all required workbooks.

    Also returns (release_month, missing_required_files) for folders that look
    like releases but are incomplete, so the caller can refuse to silently
    fall back to an older month."""
    queue: deque[tuple[str, str, list[str], int]] = deque()
    queue.append((root_id, "TARIC root", [], 0))
    visited: set[str] = set()
    candidates: list[ReleaseCandidate] = []
    incomplete_months: list[tuple[str, list[str]]] = []

    while queue:
        folder_id, folder_name, parent_path, depth = queue.popleft()
        if folder_id in visited:
            continue
        visited.add(folder_id)

        if len(visited) > max_folders:
            raise TaricError(
                f"Discovery exceeded --max-folders={max_folders}. "
                "Increase the limit if the CIRCABC hierarchy has expanded."
            )

        if depth > max_depth:
            continue

        children = fetch_children(session, folder_id, timeout)
        current_path = parent_path + ([folder_name] if folder_name else [])
        matched = match_required_files(children)

        if matched and not (REQUIRED_FILES <= set(matched)) and len(matched) >= 3:
            # VENDOR-PATCH: a folder that clearly IS a release (several target
            # workbooks present) but is missing required ones. If it is NEWER
            # than the eventually-selected release, silently building last
            # month's snapshot again would be indistinguishable from success —
            # record it so main() can fail loudly instead.
            rm, _sd, _src_ = infer_release_date_from_path(current_path)
            if rm:
                incomplete_months.append((rm, [TARGET_FILES[k] for k in REQUIRED_FILES
                                               if k not in matched]))
        if REQUIRED_FILES <= set(matched):
            candidate = candidate_from_folder(
                folder_id=folder_id,
                folder_name=folder_name,
                path_names=current_path,
                files=matched,
            )
            if year is None or (
                candidate.release_month and int(candidate.release_month[:4]) == year
            ):
                candidates.append(candidate)
                LOG.info(
                    "Found TARIC release candidate %s (%s)",
                    candidate.release_month or "unknown month",
                    folder_id,
                )
            # A complete release folder is terminal for this search; there is
            # no need to crawl its internal subfolders.
            continue

        if depth == max_depth:
            continue

        subfolders = [node for node in children if is_folder(node) and node.get("id")]
        # Newest modified first improves --verbose output and finds current
        # releases early, while still scanning all eligible folders.
        subfolders.sort(
            key=lambda n: node_modified(n)[1] or datetime.min.replace(tzinfo=timezone.utc),
            reverse=True,
        )
        for node in subfolders:
            child_name = node_display_name(node)
            child_path = current_path + [child_name]
            if year is not None and path_has_other_explicit_year(child_path, year):
                continue
            queue.append((str(node["id"]), child_name, current_path, depth + 1))

    return candidates, incomplete_months


def select_release(
    candidates: list[ReleaseCandidate],
    requested_release: str | None,
) -> ReleaseCandidate:
    if not candidates:
        raise TaricError(
            f"No complete TARIC release folder was found containing the "
            f"{len(REQUIRED_FILES)} required workbooks "
            f"({', '.join(sorted(TARGET_FILES[k] for k in REQUIRED_FILES))}). "
            "The CIRCABC hierarchy or filenames may have changed."
        )

    if requested_release:
        matching = [c for c in candidates if c.release_month == requested_release]
        if not matching:
            found = sorted({c.release_month or "unknown" for c in candidates})
            raise TaricError(
                f"Requested release {requested_release} was not found. "
                f"Discovered releases: {', '.join(found)}"
            )
        candidates = matching

    parsed = [c for c in candidates if c.release_month]
    if parsed:
        # Prefer semantic release month. Latest file-modification timestamp is
        # only a tie-breaker for duplicate folders for the same month.
        def key(c: ReleaseCandidate) -> tuple[int, int, datetime]:
            year_s, month_s = str(c.release_month).split("-")
            return (
                int(year_s),
                int(month_s),
                c.latest_modified_dt or datetime.min.replace(tzinfo=timezone.utc),
            )

        return max(parsed, key=key)

    return max(
        candidates,
        key=lambda c: c.latest_modified_dt or datetime.min.replace(tzinfo=timezone.utc),
    )


def candidate_from_explicit_folder(
    session: requests.Session,
    folder_id: str,
    timeout: int,
    release_hint: str | None,
) -> ReleaseCandidate:
    children = fetch_children(session, folder_id, timeout)
    matched = match_required_files(children)
    missing = [TARGET_FILES[k] for k in REQUIRED_FILES if k not in matched]
    if missing:
        raise TaricError(
            f"Explicit folder {folder_id} is missing required file(s): " + ", ".join(missing)
        )
    candidate = candidate_from_folder(folder_id, folder_id, [folder_id], matched)
    if release_hint:
        candidate.release_month = release_hint
        candidate.date_source = "cli_release_hint"
    return candidate


def describe_candidate(candidate: ReleaseCandidate, group_id: str) -> str:
    lines = [
        f"Release month: {candidate.release_month or 'unknown'}",
        f"Snapshot date: {candidate.snapshot_date or 'not explicitly encoded'}",
        f"Date source: {candidate.date_source}",
        f"Folder: {candidate.folder_name}",
        f"Folder ID: {candidate.folder_id}",
        f"Folder URL: {circabc_folder_ui_url(group_id, candidate.folder_id)}",
        "Required files:",
    ]
    for logical, expected in TARGET_FILES.items():
        node = candidate.files.get(logical)
        if node is None:
            lines.append(f"  - {logical}: ABSENT (optional; expected {expected})")
            continue
        lines.append(f"  - {logical}: {node_display_name(node)} [{node.get('id')}] (expected {expected})")
    return "\n".join(lines)


def download_file(
    session: requests.Session,
    node: dict[str, Any],
    destination: Path,
    timeout: int,
    force: bool,
) -> dict[str, Any]:
    node_id = str(node.get("id") or "")
    if not node_id:
        raise TaricError(f"CIRCABC file node has no id: {node_display_name(node)}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    url = circabc_download_url(node_id)

    if destination.exists() and not force:
        LOG.info("Using existing file: %s", destination)
        return {
            "downloaded": False,
            "http_etag": None,
            "http_last_modified": None,
            "content_type": None,
        }

    temp_path = destination.with_suffix(destination.suffix + ".part")
    temp_path.unlink(missing_ok=True)

    LOG.info("Downloading %s", node_display_name(node))
    try:
        with session.get(url, stream=True, timeout=timeout, allow_redirects=True) as response:
            if response.status_code in (401, 403):
                raise TaricError(
                    f"CIRCABC denied download of {node_display_name(node)} "
                    f"(HTTP {response.status_code})."
                )
            response.raise_for_status()
            with temp_path.open("wb") as fh:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        fh.write(chunk)

            result = {
                "downloaded": True,
                "http_etag": response.headers.get("ETag"),
                "http_last_modified": response.headers.get("Last-Modified"),
                "content_type": response.headers.get("Content-Type"),
            }
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise

    # An XLSX file is a ZIP container. This catches login/error HTML saved with
    # a .xlsx extension and truncated downloads before downstream processing.
    if not zipfile.is_zipfile(temp_path):
        preview = temp_path.read_bytes()[:200]
        temp_path.unlink(missing_ok=True)
        raise TaricError(
            f"Downloaded content for {node_display_name(node)} is not a valid XLSX/ZIP "
            f"container. First bytes: {preview!r}"
        )

    temp_path.replace(destination)
    return result


def _number_format_zero_width(number_format: str) -> int | None:
    """Return zero-pad width for simple Excel formats such as 0000000000."""
    fmt = number_format.strip()
    # Ignore text/color/condition sections and escaped decoration.
    if ";" in fmt or "[" in fmt or "@" in fmt or "%" in fmt:
        return None
    if re.fullmatch(r"0+", fmt):
        return len(fmt)
    return None


def cell_to_text(cell: Any) -> str:
    value = cell.value
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.isoformat(sep=" ")
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, int):
        width = _number_format_zero_width(getattr(cell, "number_format", "") or "")
        if width:
            return f"{value:0{width}d}"
        return str(value)
    if isinstance(value, float):
        if math.isnan(value):
            return "NaN"
        if math.isinf(value):
            return "Infinity" if value > 0 else "-Infinity"
        width = _number_format_zero_width(getattr(cell, "number_format", "") or "")
        if width and value.is_integer():
            return f"{int(value):0{width}d}"
        if value.is_integer():
            return str(int(value))
        # repr gives a round-trip-safe decimal string without locale changes.
        return repr(value)
    return str(value)


def export_workbook_to_csv(
    workbook_path: Path,
    csv_dir: Path,
    logical_name: str,
) -> list[CsvExport]:
    if load_workbook is None:
        raise TaricError(
            "openpyxl is required for CSV export: pip install openpyxl "
            "(or pass --skip-csv)")
    """Export every worksheet to a separate UTF-8 CSV file."""
    LOG.info("Converting workbook to CSV: %s", workbook_path.name)
    try:
        workbook = load_workbook(
            workbook_path,
            read_only=True,
            data_only=False,
            keep_links=False,
        )
    except Exception as exc:
        raise TaricError(f"Could not open workbook {workbook_path}: {exc}") from exc

    exports: list[CsvExport] = []
    sheet_names = workbook.sheetnames
    base = safe_filename(workbook_path.stem)
    csv_dir.mkdir(parents=True, exist_ok=True)

    try:
        for sheet_name in sheet_names:
            worksheet = workbook[sheet_name]
            if len(sheet_names) == 1:
                csv_name = f"{base}.csv"
            else:
                csv_name = f"{base}__{safe_filename(sheet_name, 'sheet')}.csv"
            csv_path = csv_dir / csv_name

            row_count = 0
            max_columns = 0
            with csv_path.open("w", encoding="utf-8", newline="") as fh:
                writer = csv.writer(fh, lineterminator="\n")
                for row in worksheet.iter_rows():
                    values = [cell_to_text(cell) for cell in row]
                    writer.writerow(values)
                    row_count += 1
                    max_columns = max(max_columns, len(values))

            exports.append(
                CsvExport(
                    workbook_logical_name=logical_name,
                    workbook_file=workbook_path.name,
                    sheet_name=sheet_name,
                    csv_file=str(csv_path),
                    rows=row_count,
                    columns=max_columns,
                )
            )
    finally:
        workbook.close()

    return exports


def ensure_release_format(value: str) -> str:
    if not re.fullmatch(r"20\d{2}-(0[1-9]|1[0-2])", value):
        raise argparse.ArgumentTypeError("release must be YYYY-MM, for example 2026-08")
    return value


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    with temp.open("w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False, sort_keys=False)
        fh.write("\n")
    temp.replace(path)


def build_manifest(
    *,
    candidate: ReleaseCandidate,
    group_id: str,
    root_id: str,
    output_dir: Path,
    file_records: list[dict[str, Any]],
    csv_exports: list[CsvExport],
    discovered_at: str,
) -> dict[str, Any]:
    return {
        "dataset": "EU TARIC monthly database extraction",
        "publisher": "European Commission",
        "source_system": "CIRCABC",
        "discovered_at_utc": discovered_at,
        "release": {
            "release_month": candidate.release_month,
            "snapshot_date": candidate.snapshot_date,
            "date_source": candidate.date_source,
            "latest_required_file_modified": candidate.latest_modified,
            "note": (
                "release_month identifies the monthly TARIC extraction. It is not a "
                "blanket legal effective date for all measures; duty rows can carry "
                "their own start/end dates."
            ),
        },
        "source": {
            "group_id": group_id,
            "root_folder_id": root_id,
            "root_folder_url": circabc_folder_ui_url(group_id, root_id),
            "release_folder_id": candidate.folder_id,
            "release_folder_name": candidate.folder_name,
            "release_folder_path": candidate.path_names,
            "release_folder_url": circabc_folder_ui_url(group_id, candidate.folder_id),
            "api_base": CIRCABC_API_BASE,
        },
        "output_directory": str(output_dir),
        "files": file_records,
        "csv_exports": [asdict(item) for item in csv_exports],
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Discover and download the latest monthly EU TARIC CIRCABC workbooks, "
            "then export all workbook sheets to CSV."
        )
    )
    parser.add_argument(
        "--root-id",
        default=DEFAULT_ROOT_ID,
        help=f"CIRCABC root library folder UUID (default: {DEFAULT_ROOT_ID})",
    )
    parser.add_argument(
        "--group-id",
        default=DEFAULT_GROUP_ID,
        help=f"CIRCABC group UUID used for human-facing URLs (default: {DEFAULT_GROUP_ID})",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("./eu_taric"),
        help="Output root directory (default: ./eu_taric)",
    )
    parser.add_argument(
        "--year",
        type=int,
        help="Restrict automatic discovery to one year, e.g. --year 2026",
    )
    parser.add_argument(
        "--release",
        type=ensure_release_format,
        help="Select an exact monthly release YYYY-MM instead of the latest",
    )
    parser.add_argument(
        "--folder-id",
        help=(
            "Skip recursive discovery and use this exact CIRCABC release folder UUID. "
            "Useful for debugging/backfills."
        ),
    )
    parser.add_argument(
        "--max-depth",
        type=int,
        default=4,
        help="Maximum folder depth below the configured root during discovery (default: 4)",
    )
    parser.add_argument(
        "--max-folders",
        type=int,
        default=1000,
        help="Safety cap on folders inspected during discovery (default: 1000)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=90,
        help="HTTP timeout in seconds per request (default: 90)",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Discover/select the release and print it without downloading",
    )
    parser.add_argument(
        "--list-releases",
        action="store_true",
        help="Print every complete release discovered before selecting the latest",
    )
    parser.add_argument(
        "--skip-csv",
        action="store_true",
        help="Download XLSX files but do not convert worksheets to CSV",
    )
    parser.add_argument(
        "--allow-stale-release",
        action="store_true",
        help=(
            "Proceed even when a newer month folder exists but is missing "
            "required workbooks (default: fail loudly rather than silently "
            "re-shipping the previous month)."
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Redownload files even when the target path already exists",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable debug logging",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )

    if args.max_depth < 0:
        raise TaricError("--max-depth cannot be negative")
    if args.max_folders < 1:
        raise TaricError("--max-folders must be at least 1")
    if args.release and args.year and int(args.release[:4]) != args.year:
        raise TaricError("--release and --year refer to different years")

    discovered_at = utc_now_iso()
    session = make_session()

    if args.folder_id:
        candidate = candidate_from_explicit_folder(
            session,
            args.folder_id,
            args.timeout,
            args.release,
        )
        candidates = [candidate]
    else:
        discovery_year = args.year or (int(args.release[:4]) if args.release else None)
        candidates, incomplete_months = discover_release_candidates(
            session=session,
            root_id=args.root_id,
            timeout=args.timeout,
            max_depth=args.max_depth,
            max_folders=args.max_folders,
            year=discovery_year,
        )
        candidate = select_release(candidates, args.release)
        # VENDOR-PATCH: refuse to silently ship LAST month's snapshot when a
        # NEWER month folder exists but is missing required workbooks —
        # "stale data should be visible as a failed update".
        if candidate.release_month:
            newer = [(rm, miss) for rm, miss in incomplete_months
                     if rm > candidate.release_month]
            if newer and not args.allow_stale_release:
                uniq = sorted({(rm, tuple(miss)) for rm, miss in newer})
                detail = "; ".join(f"{rm} missing {', '.join(miss)}"
                                   for rm, miss in uniq)
                raise TaricError(
                    f"A newer release folder exists but is incomplete "
                    f"({detail}). Selected {candidate.release_month} would be "
                    f"STALE. Wait for the upload to finish, or pass "
                    f"--allow-stale-release to build the older month anyway.")

    if args.list_releases:
        print("Discovered complete TARIC releases:")
        for item in sorted(
            candidates,
            key=lambda c: (c.release_month or "0000-00", c.latest_modified or ""),
        ):
            print(
                f"  {item.release_month or 'unknown':>7}  "
                f"{item.folder_id}  {item.folder_name}"
            )
        print()

    print(describe_candidate(candidate, args.group_id))
    if args.check_only:
        return 0

    # If the folder/date parser cannot determine a release month, fail before
    # writing to an ambiguous directory. Users can provide --release YYYY-MM.
    if not candidate.release_month:
        raise TaricError(
            "Could not determine the selected folder's release month. "
            "Pass --release YYYY-MM explicitly."
        )

    year = int(candidate.release_month[:4])
    release_dir = args.output_dir / str(year) / candidate.release_month
    raw_dir = release_dir / "raw"
    csv_dir = release_dir / "csv"
    raw_dir.mkdir(parents=True, exist_ok=True)

    file_records: list[dict[str, Any]] = []
    all_exports: list[CsvExport] = []

    for logical, expected_name in TARGET_FILES.items():
        node = candidate.files.get(logical)
        if node is None:
            if logical in REQUIRED_FILES:
                raise TaricError(f"Required workbook missing from release: {expected_name}")
            LOG.warning("Optional workbook absent this month: %s", expected_name)
            continue
        actual_name = node_display_name(node)
        destination = raw_dir / safe_filename(actual_name, expected_name)
        http_meta = download_file(
            session=session,
            node=node,
            destination=destination,
            timeout=args.timeout,
            force=args.force,
        )

        # Validate existing files too, not just newly downloaded ones.
        if not zipfile.is_zipfile(destination):
            raise TaricError(f"Existing file is not a valid XLSX container: {destination}")

        modified_raw, _ = node_modified(node)
        props = node.get("properties") if isinstance(node.get("properties"), dict) else {}
        record = {
            "logical_name": logical,
            "expected_name": expected_name,
            "source_name": actual_name,
            "node_id": node.get("id"),
            "details_url": circabc_file_ui_url(args.group_id, str(node.get("id"))),
            "download_url": circabc_download_url(str(node.get("id"))),
            "circabc_modified": modified_raw,
            "circabc_size": props.get("size"),
            "circabc_mimetype": props.get("mimetype"),
            "local_file": str(destination),
            "bytes": destination.stat().st_size,
            "sha256": sha256_file(destination),
            **http_meta,
        }
        file_records.append(record)

        if not args.skip_csv:
            exports = export_workbook_to_csv(destination, csv_dir, logical)
            all_exports.extend(exports)

    manifest = build_manifest(
        candidate=candidate,
        group_id=args.group_id,
        root_id=args.root_id,
        output_dir=release_dir,
        file_records=file_records,
        csv_exports=all_exports,
        discovered_at=discovered_at,
    )
    manifest_path = release_dir / "metadata.json"
    write_json(manifest_path, manifest)

    latest_pointer = {
        "dataset": "EU TARIC monthly database extraction",
        "release_month": candidate.release_month,
        "snapshot_date": candidate.snapshot_date,
        "release_folder_id": candidate.folder_id,
        "release_folder_url": circabc_folder_ui_url(args.group_id, candidate.folder_id),
        "metadata_file": str(manifest_path),
        "updated_at_utc": utc_now_iso(),
    }
    write_json(args.output_dir / "latest.json", latest_pointer)
    write_json(args.output_dir / str(year) / "latest.json", latest_pointer)

    LOG.info("Wrote metadata: %s", manifest_path)
    if all_exports:
        LOG.info("Exported %d worksheet(s) to CSV", len(all_exports))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except TaricError as exc:
        LOG.error("%s", exc)
        raise SystemExit(2)
    except requests.RequestException as exc:
        LOG.error("HTTP failure: %s", exc)
        raise SystemExit(3)
