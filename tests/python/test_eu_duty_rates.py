"""EU duty extraction: rate classification, date handling, ancestor chain,
header assertion — the pure pieces of build_duty_rates.build_eu. The full
workbook integration runs in test_full_build_from_downloads (skipped when the
curated Downloads set is absent, e.g. in CI)."""
import datetime as dt
from pathlib import Path

import pytest

import build_duty_rates as bdr

DOWNLOADS = Path("/home/wijreid/Downloads/eu_taric_august_2026")


def test_classify_rate_buckets():
    assert bdr.classify_rate("0.000 % ") == {"rate_kind": "free", "ad_valorem": 0.0}
    assert bdr.classify_rate("12.800 %")["rate_kind"] == "ad_valorem"
    assert bdr.classify_rate("12.800 %")["ad_valorem"] == 0.128
    # compound keeps its leading percentage — previously invisible to best-rate
    c = bdr.classify_rate("10.200 % + 93.100 EUR DTN")
    assert c == {"rate_kind": "compound", "ad_valorem": 0.102}
    assert bdr.classify_rate("7.600 % + EA")["rate_kind"] == "compound"
    assert bdr.classify_rate("Cond:  B cert: Y-155 (01):50.000 %")["rate_kind"] == "conditional"
    assert bdr.classify_rate("41.200 EUR DTN")["rate_kind"] == "other"


def test_date_parsing_rejects_excel_serials():
    assert bdr._parse_ddmmyyyy("01-07-2024") == dt.date(2024, 7, 1)
    assert bdr._parse_ddmmyyyy("") is None
    # the sibling TARIC-measures workbook stores serials; refusing to guess an
    # epoch is the difference between a loud failure and silently-wrong dates
    with pytest.raises(SystemExit, match="serial"):
        bdr._parse_ddmmyyyy("35796")


def test_eu_ancestor_chain():
    assert bdr._eu_ancestors("0101291000") == [
        "0101291000", "0101290000", "0101000000", "0100000000"]
    # a CN8-terminal leaf collapses onto itself at the 8-digit step (padding)
    assert bdr._eu_ancestors("0101210000")[0] == "0101210000"
    assert "0101000000" in bdr._eu_ancestors("0101210000")


def test_duties_header_assertion():
    good = {chr(ord("A") + i): c for i, c in enumerate(bdr.EXPECTED_DUTIES_COLUMNS)}
    bdr._assert_duties_header([good])          # no raise
    # leading whitespace (the TARIC-measures variant) is normalized away
    spaced = dict(good); spaced["H"] = " Measure type"; spaced["L"] = " Meas. type code"
    bdr._assert_duties_header([spaced])
    bad = dict(good); bad["J"] = "Legal base"  # column drift
    with pytest.raises(SystemExit, match="header changed"):
        bdr._assert_duties_header([bad])


def test_third_country_treatment_naming():
    # measure 103 with a non-erga-omnes origin must NOT be labelled MFN
    assert bdr.ERGA_OMNES_CODE == "1011"
    assert bdr.EU_MEASURE_DUTY["103"] == "third_country"
    assert bdr.EU_MEASURE_DUTY["112"] == "suspension"
    assert "552" in bdr.EU_MEASURE_INFO and "554" in bdr.EU_MEASURE_INFO


@pytest.mark.skipif(not DOWNLOADS.exists(), reason="curated EU workbooks absent")
def test_full_build_from_downloads(tmp_path):
    records, treatments, coverage = bdr.build_eu(
        DOWNLOADS / "Duties Import 01-99 (1).xlsx",
        DOWNLOADS / "Geographical areas composition.xlsx",
        "EU", "2026_rev_8",
        nomenclature_csv=Path("data/eu_tariff_source/eu_tariff_2026_rev_8.csv"),
        snapshot_date=dt.date(2026, 8, 1),
        exclusions_xlsx=DOWNLOADS / "Measure exclusions.xlsx",
        conditions_xlsx=DOWNLOADS / "Measure conditions.xlsx",
        addcodes_xlsx=DOWNLOADS / "Additional codes descriptions.xlsx",
    )
    by_code = {}
    for r in records:
        by_code.setdefault(r["digits"], []).append(r)
    # 0713100000: sanctions (BY/RU 50%) are separate treatments, never MFN
    peas = by_code["0713100000"]
    sanctions = [r for r in peas if r["treatment"].startswith("third_country_")]
    assert {r["origin_code"] for r in sanctions} >= {"BY", "RU"}
    assert all(r.get("conditional") for r in sanctions)
    erga = [r for r in peas if r["treatment"] == "erga_omnes"]
    assert erga and erga[0]["rate_kind"] == "conditional"
    # future-dated measures survive; genuinely expired ones do not
    assert any(r.get("valid_until", "").endswith("2026") or
               r.get("valid_until", "").endswith("2027")
               for rs in by_code.values() for r in rs)
    # coverage says where these rates apply (27 member states + XI)
    assert len(coverage["applies_in"]) == 28 and "XI" in coverage["applies_in"]
    assert coverage["excludes"]
