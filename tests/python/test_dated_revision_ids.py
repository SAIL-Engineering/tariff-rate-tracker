"""Dated editions take {year}_rev_{MMDD} of their effective date (CH 901, KR
101, TW 729). For the hand-parsed SG, MY and VN editions the id is typed into
the parser and the effective date beside it, so they can drift apart -- and a
wrong number reorders the edition against every other one (the --if-new gate,
Pinecone and ship pruning, the duty-rate route all order by (year, number)).
This holds the parser constants and every tracked CSV + .meta.json to it."""
import datetime as dt
import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PARSERS = {"sg": ("parse_sg_stcced.py", "EFFECTIVE_DATE"),
           "my": ("parse_my_pdk.py", "IN_FORCE"),
           "vn": ("parse_vn_tariff.py", "EFFECTIVE_DATE")}


def rev_id(effective: str) -> str:
    d = dt.date.fromisoformat(effective)
    return f"{d.year}_rev_{d.month}{d.day:02d}"


@pytest.mark.parametrize("cc", sorted(PARSERS))
def test_parser_revision_is_its_effective_date(cc):
    name, date_const = PARSERS[cc]
    src = (ROOT / "scripts" / "hts_automation" / name).read_text(encoding="utf-8")
    rev = re.search(r'^REVISION = "([^"]+)"', src, re.M).group(1)
    eff = re.search(rf'^{date_const} = "([^"]+)"', src, re.M).group(1)
    assert rev == rev_id(eff), f"{name}: REVISION {rev} but {date_const} {eff}"


@pytest.mark.parametrize("cc", sorted(PARSERS))
def test_every_tracked_edition_is_named_for_its_effective_date(cc):
    files = sorted((ROOT / "data" / f"{cc}_tariff_source").glob(f"{cc}_tariff_*_rev_*.csv"))
    files = [f for f in files if f.name.count(".") == 1]
    assert files
    for f in files:
        meta = json.loads(f.with_name(f.name + ".meta.json").read_text(encoding="utf-8"))
        rev = re.match(rf"^{cc}_tariff_(\d{{4}}_rev_\d+)$", f.stem).group(1)
        assert rev == rev_id(meta["effective_date"]), f.name
