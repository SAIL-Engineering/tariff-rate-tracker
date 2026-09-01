"""build_gb: measure mapping, exclusions, dedupe, coverage + reconciliation."""
from __future__ import annotations

import csv
import datetime as dt
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import build_duty_rates as bdr                          # noqa: E402

SNAPSHOT = dt.date(2026, 9, 1)


def _measures_csv(tmp_path, rows):
    p = tmp_path / "measures_as_defined.csv"
    with p.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(bdr.__dict__.get(
            "GB_MEASURE_COLUMNS", [])) or MEASURE_COLS)
        w.writeheader()
        for i, r in enumerate(rows, 1):
            w.writerow({**BLANK, "id": str(i), **r})
    return p


MEASURE_COLS = [
    "id", "commodity__sid", "commodity__code", "commodity__indent",
    "commodity__description", "measure__sid", "measure__type__id",
    "measure__type__description", "measure__additional_code__code",
    "measure__additional_code__description", "measure__duty_expression",
    "measure__effective_start_date", "measure__effective_end_date",
    "measure__reduction_indicator", "measure__footnotes",
    "measure__conditions", "measure__geographical_area__sid",
    "measure__geographical_area__id", "measure__geographical_area__description",
    "measure__excluded_geographical_areas__ids",
    "measure__excluded_geographical_areas__descriptions",
    "measure__quota__order_number", "measure__regulation__id",
    "measure__regulation__url"]
BLANK = {c: "#NA" for c in MEASURE_COLS}


def _geo_json(tmp_path):
    p = tmp_path / "geo_areas.json"
    p.write_text(json.dumps({"areas": {
        "1011": {"description": "ERGA OMNES", "members": ["CN", "JP", "US"]},
        "1013": {"description": "European Union",
                 "members": ["DE", "FR", "XI"]},
        "1080": {"description": "Channel Islands", "members": ["GG", "JE"]},
    }}))
    return p


def _nomenclature(tmp_path, leaves=("0101210000",)):
    p = tmp_path / "canonical.csv"
    with p.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["GOODS_CODE", "SUFFIX", "INDENT", "DESCRIPTION",
                    "IS_LEAF", "START_DATE"])
        for leaf in leaves:
            w.writerow([leaf, "80", "3", "x", "1", "2021-01-01"])
    return p


def _declarable(tmp_path, sample=None):
    p = tmp_path / "declarable.json"
    p.write_text(json.dumps({"declarable_sids": ["4"],
                             "sample_measures": sample or {}}))
    return p


def _build(tmp_path, rows, sample=None, leaves=("0101210000",)):
    return bdr.build_gb(_measures_csv(tmp_path, rows), _geo_json(tmp_path),
                        "GB", "2026_rev_1591",
                        nomenclature_csv=_nomenclature(tmp_path, leaves),
                        snapshot_date=SNAPSHOT,
                        declarable_json=_declarable(tmp_path, sample))


TCD = {"commodity__sid": "1", "commodity__code": "0100000000",
       "measure__sid": "20184077", "measure__type__id": "103",
       "measure__type__description": "Third country duty",
       "measure__duty_expression": "2%",
       "measure__effective_start_date": "2021-01-01",
       "measure__geographical_area__id": "1011",
       "measure__geographical_area__description": "ERGA OMNES"}


def test_erga_omnes_and_preference_mapping(tmp_path):
    records, treatments, coverage = _build(tmp_path, [
        TCD,
        {**TCD, "measure__sid": "2", "measure__type__id": "142",
         "measure__type__description": "Tariff preference",
         "measure__duty_expression": "0%",
         "measure__geographical_area__id": "1013",
         "measure__geographical_area__description": "European Union"},
    ])
    by_treat = {r["treatment"]: r for r in records}
    assert by_treat["erga_omnes"]["rate_text"] == "2%"
    assert by_treat["erga_omnes"].get("conditional") is None
    pref = by_treat["pref_1013"]
    assert pref["conditional"] is True                  # proof of origin
    tmap = {t["treatment"]: t for t in treatments}
    assert tmap["erga_omnes"]["applies"] == "all_origins"
    assert tmap["pref_1013"]["origin_countries"] == ["DE", "FR", "XI"]
    assert coverage["as_of"] == "2026-09-01"


def test_non_erga_103_is_origin_scoped_never_mfn(tmp_path):
    records, _, _ = _build(tmp_path, [
        TCD,
        {**TCD, "measure__sid": "3",
         "measure__geographical_area__id": "1080",
         "measure__geographical_area__description": "Channel Islands",
         "measure__duty_expression": "0%"},
    ])
    treats = {r["treatment"] for r in records}
    assert "third_country_1080" in treats
    ci = next(r for r in records if r["treatment"] == "third_country_1080")
    assert ci["conditional"] is True


def test_exclusions_expanded_including_eu_token(tmp_path):
    records, _, _ = _build(tmp_path, [
        TCD,
        {**TCD, "measure__sid": "5", "measure__type__id": "142",
         "measure__type__description": "Tariff preference",
         "measure__geographical_area__id": "1013",
         "measure__excluded_geographical_areas__ids": "EU|KM"},
    ])
    pref = next(r for r in records if r["treatment"] == "pref_1013")
    assert pref["excluded_origins"] == ["DE", "FR", "KM", "XI"]


def test_expired_dropped_future_deferred_current_wins(tmp_path):
    records, _, _ = _build(tmp_path, [
        {**TCD, "measure__sid": "10",
         "measure__effective_end_date": "2025-12-31"},     # expired
        {**TCD, "measure__sid": "11",
         "measure__effective_start_date": "2026-10-01",
         "measure__duty_expression": "8%"},                # future
        {**TCD, "measure__sid": "12",
         "measure__effective_start_date": "2024-01-01",
         "measure__duty_expression": "4%"},                # current older
        {**TCD, "measure__sid": "13",
         "measure__effective_start_date": "2026-01-01",
         "measure__duty_expression": "6%"},                # current newest
    ])
    ergas = [r for r in records if r["treatment"] == "erga_omnes"]
    assert len(ergas) == 1
    assert ergas[0]["rate_text"] == "6%"


def test_quota_and_remedies_are_informational(tmp_path):
    records, _, _ = _build(tmp_path, [
        TCD,
        {**TCD, "measure__sid": "20", "measure__type__id": "143",
         "measure__type__description": "Preferential tariff quota",
         "measure__quota__order_number": "058003",
         "measure__geographical_area__id": "1013"},
        {**TCD, "measure__sid": "21", "measure__type__id": "552",
         "measure__type__description": "Definitive anti-dumping duty",
         "measure__geographical_area__id": "CN",
         "measure__additional_code__code": "C999",
         "measure__duty_expression": "35.9%"},
    ])
    quota = next(r for r in records if r.get("category") == "quota")
    assert quota["informational"] and quota["conditional"]
    assert quota["quota_order_number"] == "058003"
    ad = next(r for r in records if r.get("category") == "anti_dumping")
    assert ad["add_code"] == "C999" and ad["informational"]


def test_unknown_type_lands_as_control(tmp_path):
    records, _, _ = _build(tmp_path, [
        TCD,
        {**TCD, "measure__sid": "30", "measure__type__id": "999",
         "measure__type__description": "Mystery future measure",
         "measure__geographical_area__id": "1011"},
    ])
    ctl = next(r for r in records if r.get("category") == "control")
    assert ctl["measure_name"] == "Mystery future measure"
    assert ctl["informational"]


def test_coverage_floor_fails_without_tcd(tmp_path):
    with pytest.raises(SystemExit):
        _build(tmp_path, [
            {**TCD, "measure__type__id": "142",
             "measure__type__description": "Tariff preference",
             "measure__geographical_area__id": "1013"},
        ])


def test_sampled_reconciliation_catches_unreachable(tmp_path):
    # sample says leaf sid 4 (code 0101210000) must reach measure 777, but
    # 777 is declared on an unrelated branch -> hard fail
    (tmp_path / "commodities.csv").write_text(
        "commodity__sid,commodity__code\n4,0101210000\n")
    rows = [TCD,
            {**TCD, "measure__sid": "777", "commodity__code": "9900000000",
             "measure__type__id": "142",
             "measure__type__description": "Tariff preference",
             "measure__geographical_area__id": "1013"}]
    with pytest.raises(SystemExit):
        _build(tmp_path, rows, sample={"4": ["777"]})


def test_sampled_reconciliation_passes_when_reachable(tmp_path):
    (tmp_path / "commodities.csv").write_text(
        "commodity__sid,commodity__code\n4,0101210000\n")
    records, _, _ = _build(tmp_path, [TCD], sample={"4": ["20184077"]})
    assert any(r["treatment"] == "erga_omnes" for r in records)
