"""build_explorer_dataset: Vietnam's general column states the MFN rate in force,
including the amendments enacted after the workbook (config/duty_overlays/vn.json)."""
import datetime as dt
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import build_duty_rates as bdr                              # noqa: E402
import build_explorer_dataset as bed                        # noqa: E402

OVERLAY = Path(__file__).resolve().parents[2] / "config" / "duty_overlays" / "vn.json"
AMENDMENTS = bdr._vn_amendments(json.loads(OVERLAY.read_text(encoding="utf-8")))


def general(code, cell, on):
    return bed._vn_general({"GOODS_CODE": code, "MFN_RATE": cell}, AMENDMENTS, on)


def test_amended_line_states_the_rate_in_force_not_the_stale_window():
    got = general("27101221", "10 (0% từ 09/3-30/4 theo NĐ72)", dt.date(2026, 11, 11))
    assert got == ("0% until 2026-12-31 (72/2026/NĐ-CP, extended to 2026-12-31 "
                   "by 43/2026/NQ-CP); then 10%")
    assert "30/4" not in got


def test_line_amended_after_the_workbook():
    assert general("27111900", "5", dt.date(2026, 11, 11)).startswith(
        "0% until 2026-12-31 (25/2026/NQ-CP")
    assert general("27111900", "5", dt.date(2026, 4, 15)) == "5%"


def test_after_the_window_the_base_rate():
    assert general("27101971", "7 (0% từ 09/3-30/4 theo NĐ72)", dt.date(2027, 1, 1)) == "7%"


def test_other_lines_unchanged():
    assert general("01012100", "0", dt.date(2026, 11, 11)) == "0%"
    assert general("04072100", "40 (NHN: 80)", dt.date(2026, 11, 11)) == "40 (NHN: 80)"
