import copy, json, subprocess, sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'src'))
from ieepa_fentanyl_sources import extract, ROOT
from ieepa_emergency_rules import compile_emergency, chapter98_clause, relief_actions
from chapter98_rules import treatment
from section232_stacking import amendment, vehicle_predicate, note
from section232_note16_rules import fact

@pytest.fixture(scope='module')
def source():
    rev='2025_rev_28'
    return extract(ROOT/f'data/us_notes/chapter99_{rev}.pdf',ROOT/f'data/hts_archives/hts_{rev}.json',rev)

def test_march_original_insertions_supply_conditions_and_dates():
    actions,sources=relief_actions()
    assert len(actions)==4 and len(sources)==2
    assert {a['valid_from'] for a in actions}=={'2025-03-07T00:01:00-05:00'}
    assert {a['ch99_code']:a['rate'] for a in actions}=={'9903.01.04':0,'9903.01.05':.1,'9903.01.14':0,'9903.01.15':.1}
    assert all('subchapter.' in a['source_description'] for a in actions if a['rate'])

@pytest.mark.parametrize('origin',['Canada','Mexico','China and Hong Kong'])
def test_chapter98_keeps_geography(source,origin):
    a=next(a for a in source['actions'] if ' and '.join(a['country_names'])==origin and a['entry_type']=='general')
    clause=chapter98_clause(a['source_note']);policy=treatment(clause,'ieepa_emergency')
    assert policy['geography']==origin and policy['assembly']=='98020080'
    with pytest.raises(ValueError,match='geography|valuation'):
        treatment(clause.replace('(in '+origin+')','abroad',1),'ieepa_emergency')
    with pytest.raises(ValueError,match='geography|qualifier'):
        treatment(clause+' Additional duties also apply to domestic value.','ieepa_emergency')

def test_new_note_condition_requires_review(source):
    x=copy.deepcopy(source);x['actions'][0]['source_note']+=' Except for the newly listed class.'
    with pytest.raises(ValueError,match='Unreviewed emergency legal'):compile_emergency(x,['7318158085'])

def test_order_duplicates_no_modeled_inputs_or_coverage(source):
    f=compile_emergency(source,['7318158085','8703230190'])
    x=copy.deepcopy(source);x['actions'].reverse();x['additional_sources'].reverse();x['actions']+=copy.deepcopy(x['actions'])
    other=compile_emergency(x,['8703230190','7318158085','7318158085'])
    # Stable semantic order is independent of source/action ordering.
    def semantic(fragment):
        return sorted(json.dumps(r,sort_keys=True) for r in fragment['rules'])
    assert semantic(other)==semantic(f)
    assert f['coverage']==[] and 'modeled_share' not in str(f['rules'])
    assert all(r.get('source_note_sha256') and r.get('source_heading_sha256') for r in f['rules'])
    assert any('authority_covered' in str(r['formula']) for r in f['rules'])

def test_date_windows_include_pre_amendment_minute(source):
    f=compile_emergency(source,['7318158085'])
    charged=[r for r in f['rules'] if r['reporting_codes']==['9903.01.24']]
    assert {r['scope']['from'] for r in charged}=={'2025-11-10T00:00:00-05:00','2025-11-10T00:01:00-05:00'}
    assert all(r['scope']['until']<='2025-11-13T00:00:00-05:00' for r in f['rules'])
    with pytest.raises(ValueError,match='exact HTS10'):compile_emergency(source,['73181580'])

def test_original_vehicle_amendment_and_mixed_headings(source):
    assert amendment()['effective_from']=='2025-11-01T00:01:00-04:00'
    raw=subprocess.check_output(['pdftotext','-layout',source['sources'][0]['path'],'-'],text=True)
    hts=json.loads(Path(source['sources'][1]['path']).read_bytes())
    f=lambda name,*args,**kwargs:fact(name)
    before=vehicle_predicate(hts,raw,f,False);after=vehicle_predicate(hts,raw,f,True)
    assert '9903.94.06' not in str(before) and '9903.94.06' in str(after)
    assert 's232_usmca_auto_parts_not_kits' in str(after)
    assert '9903.94.04' not in str(after) # 25-year-old vehicles are outside this waiver
    assert '9903.74.11' not in str(after) # non-MHD parts cannot trigger priority
    assert '9903.74.10' in str(after)
    assert 'not passenger vehicles' in note(raw,33)['c']
