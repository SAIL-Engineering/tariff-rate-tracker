"""Original-aircraft agreements continue as Section232 decisions after IEEPA."""
from datetime import datetime
import copy
import json
import sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'src'))


def test_evidence_order_and_identical_duplicates_do_not_change_roles():
    from section232_civil_aircraft import load_evidence,ROOT
    meta=json.loads((ROOT/'resources/legal_evidence/section232/civil-aircraft/sources.json').read_bytes())
    expected=load_evidence(meta)
    meta['sources']=list(reversed(meta['sources']))+[copy.deepcopy(meta['sources'][0])]
    assert load_evidence(meta)==expected


def test_original_operands_reconcile_all_preserved_partner_actions():
    from section232_civil_aircraft import load_history
    h=load_history()
    assert len(h['actions'])==4
    assert {r['country_text'] for r in h['other_authority_relief']}=={'Switzerland','Liechtenstein'}
    assert all(r['determination']=='reciprocal_relief_only_no_section232_concession_in_this_clause' for r in h['other_authority_relief'])
    assert h['modern_from']=='2026-04-06T00:01:00-04:00'
    modern={'9903.82.02',*(f'9903.82.{i:02}' for i in range(4,18))}
    for a in h['actions']:
        assert len(a['periods'])==2
        before,after=a['periods']
        assert before['until']==after['from_']==h['modern_from']
        assert modern<=set(after['target_reporting_codes'])
        assert not modern&set(before['target_reporting_codes'])
        assert '9903.82.03' not in after['target_reporting_codes']
        assert datetime.fromisoformat(before['from_'])<datetime.fromisoformat('2026-02-24T00:00:00-05:00')<datetime.fromisoformat(before['until'])
        assert after['source_ids'] and after['amendment_locators']


def test_preservation_clause_must_remain_reviewed(monkeypatch):
    import section232_civil_aircraft as m
    x=copy.deepcopy(m.load_evidence())
    assert 'does not alter or supersede' in x['body']
    x['body']=x['body'].replace('does not alter or supersede','hereby supersedes')
    monkeypatch.setattr(m,'load_evidence',lambda:x)
    with pytest.raises(ValueError,match='preserv'):m.load_history()


def test_conflicting_same_operand_replacements_do_not_choose_arbitrarily(monkeypatch):
    import section232_civil_aircraft as m
    x=copy.deepcopy(m.load_evidence())
    assert '9903.82.04–9903.82.17' in x['annex']
    x['annex']=x['annex'].replace('9903.82.04–9903.82.17','9903.82.05–9903.82.17',1)
    monkeypatch.setattr(m,'load_evidence',lambda:x)
    with pytest.raises(ValueError,match='Conflicting'):m.load_history()


def test_post_collection_rules_are_independent_and_keep_exact_scope():
    from section232_civil_aircraft import load_history,compile_rules
    h=load_history()
    actual={'United Kingdom':['4120'],'European Union':['4280'],'Japan':['5880'],'South Korea':['5800']}
    jurisdictions={a['reporting_code']:actual[a['country_text']] for a in h['actions']}
    f=compile_rules('2026_rev_4',['7304313000','8473301180'],jurisdictions)
    assert f['rules'] and not f['coverage']
    assert all(r['authority']=='section_232' and r['reporting_only'] for r in f['rules'])
    assert all(r['scope']['hts_exact']==['7304313000'] for r in f['rules'])
    assert all(e['target_authority']=='section_232' for e in f['relations'])
    assert all(r['formula']=={'value':0} for r in f['rules'])
    assert datetime.fromisoformat(f['supported_until'])>datetime.fromisoformat('2026-02-24T00:00:00-05:00')
    with pytest.raises(ValueError,match='origin'):compile_rules('2026_rev_4',['7304313000'],{})
