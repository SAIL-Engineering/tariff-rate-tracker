"""usitc_native: pure-logic tests (network mocked); parity semantics that were
also verified live against the R originals (byte-identical outputs)."""
from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import usitc_native as u                                  # noqa: E402


# ─── id parsing / naming ─────────────────────────────────────────────

@pytest.mark.parametrize("rev,expected", [
    ("2026_rev_3", (2026, "rev_3")),
    ("2026_basic", (2026, "basic")),
    ("rev_32", (2025, "rev_32")),
    ("basic", (2025, "basic")),
])
def test_parse_revision_id(rev, expected):
    assert u.parse_revision_id(rev) == expected


@pytest.mark.parametrize("name,expected", [
    ("2026HTSRev4", "2026_rev_4"),
    ("2025HTSBasic", "2025_basic"),
    ("2026HTSRev17", "2026_rev_17"),
    ("garbage", None),
    ("2026HTSRevX", None),
])
def test_api_name_to_revision(name, expected):
    assert u.api_name_to_revision(name) == expected


@pytest.mark.parametrize("rev,fmt,url", [
    ("2026_rev_17", "json", f"{u.BASE_URL}/hts_2026_revision_17_json.json"),
    ("2026_rev_17", "csv", f"{u.BASE_URL}/hts_2026_revision_17_csv.csv"),
    ("2026_basic", "json", f"{u.BASE_URL}/hts_2026_basic_edition_json.json"),
    ("2022_basic", "json", f"{u.BASE_URL}/hts_2022_basic_json.json"),   # pre-2023: no _edition
    ("rev_3", "csv", f"{u.BASE_URL}/hts_2025_revision_3_csv.csv"),
])
def test_build_download_url(rev, fmt, url):
    assert u.build_download_url(rev, fmt) == url


# ─── CSV merge + rewrite fidelity ────────────────────────────────────

HEADER = ",".join(u.FIELDS)


def _seed(tmp_path, rows):
    p = tmp_path / "revision_dates.csv"
    body = "\n".join(",".join(r.get(f, "NA") for f in u.FIELDS) for r in rows)
    p.write_text(HEADER + "\n" + body + "\n")
    return p


def test_update_appends_only_new_sorted_and_na_filled(tmp_path):
    p = _seed(tmp_path, [
        {"revision": "2026_rev_17", "effective_date": "2026-08-24",
         "needs_review": "FALSE"},
    ])
    changed = u.update_revision_dates(p, [
        {"revision": "2026_rev_17", "effective_date": dt.date(2026, 8, 24),
         "name": "2026HTSRev17"},                          # known → ignored
        {"revision": "2026_rev_18", "effective_date": dt.date(2026, 9, 15),
         "name": "2026HTSRev18"},                          # new → appended
    ])
    assert changed
    lines = p.read_text().splitlines()
    assert lines[0] == HEADER
    assert lines[1].startswith("2026_rev_17,")             # date-sorted
    # policy_event contains commas → minimally quoted, like readr's write_csv
    assert lines[2].startswith('2026_rev_18,2026-09-15,NA,NA,"[REVIEW] added ')
    assert lines[2].endswith('",NA,TRUE,NA,NA,NA,NA,NA,NA')
    assert p.read_text().endswith("\n")
    # readr fidelity: LF only, no CRLF
    assert "\r" not in p.read_text()


def test_update_no_new_is_a_no_op(tmp_path):
    p = _seed(tmp_path, [{"revision": "2026_rev_17",
                          "effective_date": "2026-08-24"}])
    before = p.read_bytes()
    assert not u.update_revision_dates(p, [
        {"revision": "2026_rev_17", "effective_date": dt.date(2026, 8, 24),
         "name": "2026HTSRev17"}])
    assert p.read_bytes() == before


def test_existing_cells_pass_through_verbatim(tmp_path):
    p = _seed(tmp_path, [
        {"revision": "2026_rev_16", "effective_date": "2026-07-30",
         "policy_event": "some curated text", "needs_review": "FALSE"},
    ])
    u.update_revision_dates(p, [
        {"revision": "2026_rev_18", "effective_date": dt.date(2026, 9, 1),
         "name": "2026HTSRev18"}])
    assert "some curated text" in p.read_text()


# ─── auto-clear ──────────────────────────────────────────────────────

def test_auto_clear_decision_table(tmp_path):
    today = dt.date.today()
    good = (today + dt.timedelta(days=10))
    stale = (today - dt.timedelta(days=90))
    p = _seed(tmp_path, [
        {"revision": f"{good.year}_rev_50", "effective_date": good.isoformat(),
         "needs_review": "TRUE"},                          # clears
        {"revision": f"{stale.year}_rev_51", "effective_date": stale.isoformat(),
         "needs_review": "TRUE"},                          # too old — kept
        {"revision": "1999_rev_52", "effective_date": good.isoformat(),
         "needs_review": "TRUE"},                          # year mismatch — kept
        {"revision": "2026_rev_53", "effective_date": "not-a-date",
         "needs_review": "TRUE"},                          # unparseable — kept
    ])
    assert u.auto_clear_needs_review(p) == 1
    rows = {r["revision"]: r for r in u._read_rows(p)}
    assert rows[f"{good.year}_rev_50"]["needs_review"] == "FALSE"
    assert rows[f"{stale.year}_rev_51"]["needs_review"] == "TRUE"
    assert rows["1999_rev_52"]["needs_review"] == "TRUE"
    assert rows["2026_rev_53"]["needs_review"] == "TRUE"


# ─── latest ──────────────────────────────────────────────────────────

def test_latest_picks_max_eligible_and_formats_label(tmp_path):
    p = _seed(tmp_path, [
        {"revision": "2026_rev_17", "effective_date": "2026-08-24",
         "needs_review": "FALSE"},
        {"revision": "2026_rev_18", "effective_date": "2026-09-05",
         "needs_review": "TRUE"},                          # ineligible
        {"revision": "2026_rev_16", "effective_date": "2026-07-30",
         "needs_review": "NA"},
    ])
    kv = u.latest_revision(p)
    assert kv["REV_ID"] == "2026_rev_17"
    assert kv["EFFECTIVE_DATE_LABEL"] == "August 24, 2026"   # non-padded day
    assert kv["JSON_PATH"] == "data/hts_archives/hts_2026_rev_17.json"
    assert kv["CSV_PATH"] == "data/hts_archives_csv/hts_2026_rev_17.csv"


def test_latest_label_single_digit_day(tmp_path):
    p = _seed(tmp_path, [{"revision": "2026_rev_1",
                          "effective_date": "2026-03-04"}])
    assert u.latest_revision(p)["EFFECTIVE_DATE_LABEL"] == "March 4, 2026"


def test_latest_override_needs_review_fails(tmp_path):
    p = _seed(tmp_path, [{"revision": "2026_rev_18",
                          "effective_date": "2026-09-05",
                          "needs_review": "TRUE"}])
    with pytest.raises(SystemExit):
        u.latest_revision(p, "2026_rev_18")
    with pytest.raises(SystemExit):
        u.latest_revision(p)                               # nothing eligible


def test_latest_basic_revision_paths(tmp_path):
    p = _seed(tmp_path, [{"revision": "2026_basic",
                          "effective_date": "2026-01-01"}])
    kv = u.latest_revision(p)
    assert kv["REV_NUM"] == "basic"
    assert kv["JSON_PATH"].endswith("hts_2026_basic.json")
