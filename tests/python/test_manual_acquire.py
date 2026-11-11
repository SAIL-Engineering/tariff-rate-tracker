"""acquire/manual.py picks the newest edition by revision id, not by mtime."""
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"))

from acquire import manual  # noqa: E402


def _edition(d: Path, stem: str, eff: str, mtime: int) -> None:
    csv = d / f"{stem}.csv"
    csv.write_text("GOODS_CODE\n", encoding="utf-8")
    (d / f"{stem}.csv.meta.json").write_text(json.dumps({"effective_date": eff}))
    (d / f"{stem}.vi.csv").write_text("GOODS_CODE\n", encoding="utf-8")
    os.utime(csv, (mtime, mtime))


def _resolve(d: Path):
    spec = {"acquire": {"manual_dir": str(d), "manual_prefix": "vn_tariff"}}
    return manual.resolve(spec, SimpleNamespace(source=None, revision=None,
                                                effective_date=None))


def test_newest_revision_wins_even_when_an_older_file_was_touched_last(tmp_path):
    _edition(tmp_path, "vn_tariff_2026_rev_1201", "2026-12-01", mtime=1_000)
    _edition(tmp_path, "vn_tariff_2026_rev_405", "2026-04-05", mtime=2_000)
    got = _resolve(tmp_path)
    assert got.rev_id == "2026_rev_1201" and got.effective_date == "2026-12-01"


def test_a_new_year_beats_a_larger_day_and_month_number(tmp_path):
    _edition(tmp_path, "vn_tariff_2026_rev_1201", "2026-12-01", mtime=2_000)
    _edition(tmp_path, "vn_tariff_2027_rev_301", "2027-03-01", mtime=1_000)
    assert _resolve(tmp_path).rev_id == "2027_rev_301"


def test_language_variants_and_sidecars_are_never_the_source(tmp_path):
    _edition(tmp_path, "vn_tariff_2026_rev_405", "2026-04-05", mtime=1_000)
    got = _resolve(tmp_path)
    assert got.source_csv.endswith("vn_tariff_2026_rev_405.csv")
