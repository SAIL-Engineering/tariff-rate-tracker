"""build_ch: NT/PR mapping, privilege baseline, VAT rows, group expansion."""
from __future__ import annotations

import csv
import datetime as dt
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import build_duty_rates as bdr                          # noqa: E402

SNAP = dt.date(2026, 9, 1)
V = '<validFrom>2012-01-01</validFrom><validTo>2999-12-31</validTo>'


def _rate(val, typ, grp, vf="2012-01-01"):
    return (f'<rate><value>{val}</value><type>{typ}</type>'
            f'<weight>ADD_VOL</weight><factor>1</factor>'
            f'<countryGrpNr>{grp}</countryGrpNr><gebCode>0</gebCode>'
            f'<dbr>J</dbr><period/><validFrom>{vf}</validFrom>'
            f'<validTo>2999-12-31</validTo></rate>')


def _commodity(code, privs, text="ordinary goods", vat=""):
    priv_xml = "".join(
        f'<customsPrivilegeCode><tariffLine>J</tariffLine>'
        f'<code>{pc}</code>{V}{rates}</customsPrivilegeCode>'
        for pc, rates in privs)
    return (f'<commodityCode><value>{code}</value>{V}'
            f'<periodFrom>01.01.</periodFrom><periodTo>31.12.</periodTo>'
            f'<validForImport>true</validForImport>'
            f'<validForExport>false</validForExport>'
            f'<commodityCodeText><type>T</type><textDe>d</textDe>'
            f'<textFr>f</textFr><textIt>i</textIt><textEn>{text}</textEn>'
            f'{V}</commodityCodeText>{priv_xml}{vat}</commodityCode>')


def _master(tmp_path, commodities):
    p = tmp_path / "TariffMasterData_v6.xml"
    p.write_text(f'<tariffMasterData created="2026-09-01T18:25:14">'
                 f'<commodityCodes>{"".join(commodities)}</commodityCodes>'
                 f'</tariffMasterData>', encoding="utf-8")
    return p


def _countries(tmp_path):
    p = tmp_path / "CountryCodes_v3.xml"
    p.write_text(f'''<countryCodes created="2026-08-14T18:08:39">
<countryGroups>
  <countryGroup grpNr="100000" nameEn="Normal rate" validFrom="1988-01-01" validTo="2999-12-31"/>
  <countryGroup grpNr="100001" nameEn="European Union" validFrom="1988-01-01" validTo="2999-12-31"/>
  <countryGroup grpNr="100003" nameEn="Developing countries" validFrom="1988-01-01" validTo="2999-12-31"/>
</countryGroups>
<countries>
  <country isoCode="DE" nameEn="Germany" validFrom="1988-01-01" validTo="2999-12-31">
    <countryGroupAssignment grpNr="100000" validFrom="1988-01-01" validTo="2999-12-31"/>
    <countryGroupAssignment grpNr="100001" validFrom="1988-01-01" validTo="2999-12-31"/>
  </country>
  <country isoCode="BD" nameEn="Bangladesh" validFrom="1988-01-01" validTo="2999-12-31">
    <countryGroupAssignment grpNr="100003" validFrom="1988-01-01" validTo="2999-12-31"/>
  </country>
  <country isoCode="XX" nameEn="Gone" validFrom="1988-01-01" validTo="2000-01-01">
    <countryGroupAssignment grpNr="100001" validFrom="1988-01-01" validTo="2999-12-31"/>
  </country>
</countries></countryCodes>''', encoding="utf-8")
    return p


def _nomenclature(tmp_path, codes):
    p = tmp_path / "canonical.csv"
    with p.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["GOODS_CODE", "SUFFIX", "INDENT", "DESCRIPTION", "UNIT",
                    "IS_LEAF", "GT_RATE", "START_DATE"])
        for c in codes:
            w.writerow([c, "80", "3", "x", "Fr. per piece(s)", "1", "120.0",
                        "2012-01-01"])
    return p


def _base(tmp_path):
    p = tmp_path / "TariffBaseMasterData_v2.xml"
    p.write_text('<baseMasterData created="2026-09-01T18:17:10"/>',
                 encoding="utf-8")
    return p


def _build(tmp_path, commodities, codes):
    return bdr.build_ch(_master(tmp_path, commodities),
                        _countries(tmp_path), "CH", "2026_rev_901",
                        nomenclature_csv=_nomenclature(tmp_path, codes),
                        snapshot_date=SNAP, base_xml=_base(tmp_path),
                        created="2026-09-01T18:25:14")


def test_nt_pr_mapping_and_specific_rates(tmp_path):
    com = _commodity("0101.2110",
                     [("00", _rate("120.0", "NT", "100000")
                             + _rate("0", "PR", "100001"))])
    records, treatments, coverage = _build(tmp_path, [com], ["01012110"])
    by = {r["treatment"]: r for r in records if r.get("category") is None
          or r.get("category") == "duty"}
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert erga["rate_text"] == "CHF 120.0 per piece(s)"     # specific, verbatim
    assert erga["rate_kind"] == "other"                       # never a percent
    pref = next(r for r in records if r["treatment"] == "pref_100001")
    assert pref["rate_text"] == "Free" and pref["conditional"] is True
    tmap = {t["treatment"]: t for t in treatments}
    # validity-filtered membership: XX (ended 2000) must not appear
    assert tmap["pref_100001"]["origin_countries"] == ["DE"]
    assert coverage["applies_in"] == ["LI"]
    assert "master data 2026-09-01T18:25:14" in coverage["as_of"]


def test_use_bound_line_baseline_is_lowest_privilege(tmp_path):
    com = _commodity("0102.2911",
                     [("01", _rate("38.0", "NT", "100000"))],
                     text="for slaughter")
    records, _, _ = _build(tmp_path, [com], ["01022911"])
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert erga["conditional"] is True                # use-bound
    assert erga["privilege_code"] == "01"


def test_non_baseline_privileges_stay_separate(tmp_path):
    com = _commodity("0101.2190",
                     [("00", _rate("120.0", "NT", "100000")),
                      ("01", _rate("10.0", "NT", "100000"))])
    records, _, _ = _build(tmp_path, [com], ["01012190"])
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert erga["rate_text"].startswith("CHF 120.0")
    priv = next(r for r in records if r.get("category") == "privilege")
    assert priv["informational"] and priv["privilege_code"] == "01"
    assert priv["rate_text"].startswith("CHF 10.0")


def test_quota_lines_are_conditional(tmp_path):
    com = _commodity("0101.2110",
                     [("00", _rate("120.0", "NT", "100000"))],
                     text="within the limits of the tariff quota (Q. No. 1)")
    records, _, _ = _build(tmp_path, [com], ["01012110"])
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert erga["conditional"] is True
    assert "quota" in erga["quota_note"].lower()


def test_per_code_vat_rows(tmp_path):
    vat = (f'<vatCode><code>2</code><textEn>reduced</textEn>{V}'
           f'<vatRate><rate>2.60</rate><validFrom>2024-01-01</validFrom>'
           f'<validTo>2999-12-31</validTo></vatRate>'
           f'<vatRate><rate>2.50</rate><validFrom>2018-01-01</validFrom>'
           f'<validTo>2023-12-31</validTo></vatRate></vatCode>')
    com = _commodity("0101.2110",
                     [("00", _rate("0", "NT", "100000"))], vat=vat)
    records, _, _ = _build(tmp_path, [com], ["01012110"])
    v = next(r for r in records if r.get("category") == "vat")
    assert v["rate_text"] == "2.60%" and v["vat_code"] == "2"


def test_commodity_set_must_match_leaves(tmp_path):
    com = _commodity("0101.2110", [("00", _rate("0", "NT", "100000"))])
    with pytest.raises(SystemExit):
        _build(tmp_path, [com], ["01012110", "99999999"])   # tree-only leaf


def test_expired_and_future_rates_resolve_to_current(tmp_path):
    rates = (_rate("100.0", "NT", "100000", vf="2012-01-01")
             + _rate("80.0", "NT", "100000", vf="2020-01-01")
             + _rate("60.0", "NT", "100000", vf="2027-01-01"))
    # future-start row is still "active" by validity window start>snapshot?
    com = _commodity("0101.2110", [("00", rates)])
    records, _, _ = _build(tmp_path, [com], ["01012110"])
    ergas = [r for r in records if r["treatment"] == "erga_omnes"]
    assert len(ergas) == 1
    assert ergas[0]["rate_text"].startswith("CHF 80.0")     # newest current
