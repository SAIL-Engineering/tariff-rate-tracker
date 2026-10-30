"""Part roles retain source precision, elections, conditions and legal instants."""
import copy
import json
from pathlib import Path
import sys
import pytest

ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'src'))
from section232_mhd_parts import load_history,extract,compile_rules,memberships,reconcile,assert_native_presence
from section232_autos import extract as auto_extract,compile_rules as auto_compile


@pytest.fixture(scope='module')
def native():return extract('2026_rev_10')


def test_original_parts_and_certified_roles_are_distinct(native):
    h=load_history()
    assert h['from_']=='2025-11-01T00:01:00-04:00'
    assert h['rate']==.25 and len(h['scope'])==182
    assert h['roles']==dict(listed='9903.74.08',certified='9903.74.09',usmca='9903.74.10',non_part='9903.74.11')
    groups=memberships(h,['4009120020','4009120050','8544429090','7320106015'],native['auto_scope'])
    assert groups==dict(listed=['4009120020','7320106015'],certified=['4009120050','8544429090'])
    assert '40091200' not in h['scope']


def test_original_amendments_drive_windows_not_release_dates():
    ps=load_history()['periods']
    assert [p['from_'] for p in ps]==['2025-11-01T00:01:00-04:00','2026-04-06T00:01:00-04:00',
        '2026-04-23T00:01:00-05:00','2026-06-08T00:01:00-04:00']
    assert '9903.78.01' in ps[0]['targets'] and '9903.82.02' not in ps[0]['targets']
    assert '9903.78.01' not in ps[1]['targets'] and '9903.82.17' in ps[1]['targets']
    assert '9903.82.19' not in ps[1]['targets'] and '9903.82.19' in ps[2]['targets']
    assert '9903.82.26' in ps[3]['targets']
    assert all('9903.82.03' not in p['targets'] for p in ps)  # no authority-wide erasure


def test_deduplication_and_no_aggregate_shares(native):
    ps=['4009120020','8544429090']
    a=compile_rules(native,ps);b=compile_rules(native,ps[::-1]*2)
    assert a==b
    assert not a['coverage']
    ast=json.dumps(a['rules'])
    assert 'copper_share' not in ast and 'assembly_credit' not in ast and 'model' not in ast
    assert 'SECTION_232_MHD_IMPORT_OFFSET' in ast
    assert any(e['trigger_test']=='applicability' for e in a['relations'])


def test_unreviewed_scope_claim_or_rate_must_fail(native):
    for k in 'hijkl':
        c=copy.deepcopy(native['clauses']);c[k]+=' An additional new condition applies.'
        with pytest.raises(ValueError):reconcile(c,native['headings'],load_history())
    hs=copy.deepcopy(native['headings'])
    next(r for r in hs if r['htsno']=='9903.74.09')['special']='Free'
    with pytest.raises(ValueError):reconcile(native['clauses'],hs,load_history())
    changed=copy.deepcopy(native);changed['auto_scope'].append('8544')
    with pytest.raises(ValueError,match='changed after'):compile_rules(changed,['8544429090'])


def test_certified_parts_have_exact_country_roles_and_no_listed_scope_widening():
    x=auto_extract(ROOT/'data/us_notes/chapter99_2026_rev_10.pdf',ROOT/'data/hts_archives/hts_2026_rev_10.json','2026_rev_10')
    f=auto_compile(x,['4009120020','4009120050','8544429090','7320106015'],{'all':['2010','4120','4279','5880','5800','5830'],
        'United Kingdom':['4120'],'European Union':['4279'],'Japan':['5880'],'South Korea':['5800'],'Taiwan':['5830']})
    certified=[r for r in f['rules'] if r['action_id']=='s232_certified_automobile_parts']
    assert certified
    assert {p for r in certified for p in r['scope']['hts_exact']}=={'4009120050','8544429090'}
    assert all('s232_vehicle_parts_certification' in str(r['when']) for r in certified)
    for code in ['9903.94.07','9903.94.33','9903.94.44','9903.94.45','9903.94.54','9903.94.55',
        '9903.94.64','9903.94.65','9903.94.68','9903.94.69']:
        assert any(code in r['reporting_codes'] for r in certified)
    for k in 'pqr':
        changed=copy.deepcopy(x);changed['clauses'][k]+=' An additional new condition applies.'
        with pytest.raises(ValueError):auto_compile(changed,['8544429090'],{'all':['2010']})


def test_lost_operative_headings_and_unreviewed_qualifications_do_not_become_zero():
    h=load_history()
    with pytest.raises(ValueError,match='headings disappear'):
        assert_native_presence('2026_rev_21',{},h)
    assert_native_presence('2025_rev_6',{},h)
    x=auto_extract(ROOT/'data/us_notes/chapter99_2026_rev_10.pdf',ROOT/'data/hts_archives/hts_2026_rev_10.json','2026_rev_10')
    x['clauses']['g']=x['clauses']['g'].replace('this subdivision:','this subdivision, subject to an additional condition:')
    with pytest.raises(ValueError):auto_compile(x,['8544429090'],{'all':['2010']})
