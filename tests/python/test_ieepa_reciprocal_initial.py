import copy,json,sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'src'))
from ieepa_reciprocal_initial import original,initial_history
from chapter98_rules import treatment

@pytest.fixture(scope='module')
def h():return initial_history()

def test_original_country_table_reconciles_with_independent_note(h):
    assert len(h['actions'])==34
    table={r['code']:r for r in h['actions']}
    assert table['9903.01.50']['country_text']=='the European Union or Jordan'
    assert table['9903.01.50']['rate']==.2
    assert table['9903.01.63']['rate']==.34
    assert table['9903.01.76']['country_text']=='Lesotho'
    assert h['baseline_rate']==.1

def test_china_replacements_are_original_operations(h):
    first,second=h['amendments']
    assert (first['old_rate'],first['rate'],first['from_'])==(.34,.84,'2025-04-09T00:01:00-04:00')
    assert (second['old_rate'],second['rate'],second['from_'])==(.84,1.25,'2025-04-10T00:01:00-04:00')
    assert h['china_suspension_from']=='2025-05-14T00:01:00-04:00'
    assert h['suspension_until']=='2025-07-09T00:01:00-04:00'

def test_subsequent_portion_amendment_bounds_old_policy(h):
    assert h['metal_portion_from']=='2025-06-04T00:01:00-04:00'
    assert h['uk_aircraft']['from_']=='2025-06-30T00:01:00-04:00'
    assert h['policy_until']=='2025-08-01T00:01:00-04:00'
    assert any(s['id']=='FR-2025-10524' for s in h['sources'])

def test_july_extension_and_uk_aircraft_are_original_source_conditions(h):
    assert h['suspension_extension']['from_']=='2025-07-09T00:01:00-04:00'
    assert h['suspension_extension']['until']=='2025-08-01T00:01:00-04:00'
    uk=h['uk_aircraft']
    assert uk['reporting_code']=='9903.96.01'
    assert '73043130' in uk['products']
    assert len(uk['products'])==565
    assert '9903.81.94' in uk['removed_codes']
    assert '9903.01.25' in uk['removed_codes']
    assert h['china_suspension_until']=='2025-08-12T00:01:00-04:00'

def test_non_china_extension_cannot_carry_china_past_its_own_source_window(monkeypatch):
    import ieepa_reciprocal_initial as m
    actual=m.verified_source
    def changed(doc):
        text,source=actual(doc)
        if doc=='EO-14316':text=text.replace('August 1, 2025','November 1, 2025')
        return text,source
    monkeypatch.setattr(m,'verified_source',changed)
    with pytest.raises(ValueError,match='China suspension'):m.initial_history()

def test_named_zero_metal_and_actual_auto_heading_inventory(h):
    assert '9903.81.92' in h['section232']['vii']
    assert '9903.85.09' in h['section232']['ix']
    assert h['section232']['xi']==['9903.94.05']
    assert not any('9903.94.06' in v for v in h['section232'].values())

def test_original_chapter98_semicolon_keeps_valuation_exceptions(h):
    p=treatment(h['clauses']['i'])
    assert p['repairs']==['98020040','98020050','98020060']
    assert p['assembly']=='98020080'
    with pytest.raises(ValueError,match='Uncompiled'):
        treatment(h['clauses']['i'].replace('; and subheadings','; other articles and subheadings'))

def test_cbp_transit_supersession_is_retained(h):
    assert h['transit_until']=='2025-06-16T00:01:00-04:00'
    assert h['transit_source_id']=='CBP-CSMS-65201773'
    assert {'CBP-CSMS-64680374','CBP-CSMS-65201773'}<={s['id'] for s in h['sources']}

def test_heading_table_unknown_country_or_rate_is_rejected(monkeypatch):
    import ieepa_reciprocal_initial as m
    actual=m.annex
    def changed(doc):
        text,source=actual(doc)
        # Change the operative table while retaining the independent note.
        return text.replace('Cameroon or the Democratic','Unreviewed country or the Democratic',1),source
    monkeypatch.setattr(m,'annex',changed)
    with pytest.raises(ValueError,match='disagree'):m.original()

def test_country_note_missing_member_is_rejected(monkeypatch):
    import ieepa_reciprocal_initial as m
    actual=m.annex
    def changed(doc):
        text,source=actual(doc)
        return text.replace('57)       Zimbabwe','58)       Zimbabwe'),source
    monkeypatch.setattr(m,'annex',changed)
    with pytest.raises(ValueError,match='Incomplete'):m.original()
