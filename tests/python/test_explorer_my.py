"""build_explorer_dataset: Malaysia's general column states the import duty in
force, including the amendments made after the Customs Duties Order 2025
(config/duty_overlays/my.json)."""
import datetime as dt
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import build_duty_rates as bdr                              # noqa: E402
import build_explorer_dataset as bed                        # noqa: E402

OVERLAY = Path(__file__).resolve().parents[2] / "config" / "duty_overlays" / "my.json"
AMENDMENTS = bdr._my_amendments(json.loads(OVERLAY.read_text(encoding="utf-8")))


def general(code, cell, on):
    return bed._my_general({"GOODS_CODE": code, "IMPORT_RATE": cell}, AMENDMENTS, on)


def test_before_commencement_the_gazette_rate_and_what_follows():
    assert general("7115901000", "10%", dt.date(2026, 10, 31)) == (
        "10% until 2026-10-31; then 0% (P.U. (A) 350/2026)")


def test_from_commencement_the_amended_rate():
    assert general("7115901000", "10%", dt.date(2026, 11, 1)) == (
        "0% from 2026-11-01 (P.U. (A) 350/2026); 10% before")


def test_other_lines_unchanged():
    assert general("7115902000", "10%", dt.date(2026, 11, 1)) == "10%"
    assert general("2204211100", "RM 7.00", dt.date(2026, 11, 1)) == "RM 7.00"


def test_a_gazette_that_has_moved_on_stops_the_build():
    with pytest.raises(SystemExit, match="expects the gazette to print '10%'"):
        general("7115901000", "0%", dt.date(2026, 11, 1))
