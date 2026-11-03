import copy, csv, json, sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'src'))
from section338_sources import extract,periods,ROOT
from build_contract import audit_until
from section338_rules import compile_rules,interaction_codes
from chapter98_rules import treatment

@pytest.fixture(scope='module')
def source():return extract()

def test_original_tables_reconcile_all_projection_rows(source):
    expected={(r['program'],r['ch99_heading'],r['hts8']) for r in csv.DictReader((ROOT/'resources/s338_products.csv').open())}
    actual={(a['program'],a['heading'],p) for a in source['actions'] for p in a['products']}
    assert actual==expected
    assert [len(a['products']) for a in source['actions']]==[63,52,439]
    assert set(source['aircraft']['products'])=={r['hts8'] for r in csv.DictReader((ROOT/'resources/s338_gn6_exempt_products.csv').open())}
    assert all(a['rate']==.5 and a['from_']=='2026-08-22T00:01:00-04:00' for a in source['actions'])

def test_original_amendments_reconcile_at_exact_precision(source):
    projected=json.loads((ROOT/'resources/s338_amendments.json').read_bytes())
    for a,b in zip(source['amendments'],projected):
        for key in ('id','program','effective_at','s232_exempt'):assert a[key]==b[key]
        for key in ('insert','delete'):assert set(a[key])==set(b[key])
    windows=periods(source)
    assert len(windows)==6
    assert all(w['s232_exempt'] for w in windows if w['program']=='dairy')
    assert {w['until'] for w in windows if 'amendment_id' not in w}=={'2026-09-15T00:01:00-04:00',audit_until()}
    a=next(w for w in windows if w.get('amendment_id')=='2026-18838')
    assert '22083060' not in a['products'] and '2208306075' in a['products'] and '2208306085' not in a['products']

def test_scope_only_amendment_carries_section232_cumulation_forward(source):
    windows=periods(source)
    prior=next(w for w in windows if w.get('amendment_id')=='2026-18839')
    later=next(w for w in windows if w.get('amendment_id')=='2026-22292')
    # Proclamation 11076 issues no subdivision (c) instruction. Cumulation must
    # carry forward from the September amendment, not revert to the original
    # exemption, and the September state is its required predecessor.
    assert later['program']=='motor_vehicles' and later['from_']=='2026-10-30T00:01:00-04:00'
    assert not prior['s232_exempt'] and not later['s232_exempt']
    assert prior['until']=='2026-10-30T00:01:00-04:00'
    # Counts reconcile against codified note 51(b)(3): 513 codes in revision 21,
    # 591 in revision 22, both including six ten-digit statistical codes.
    assert len(prior['products'])==513 and len(later['products'])==591
    assert set(later['products'])==set(prior['products'])-set(a_deleted(source))|set(a_inserted(source))
    assert '12122100' in prior['products'] and '12122100' not in later['products']
    assert '18061005' not in prior['products'] and '18061005' in later['products']

def a_deleted(source):
    return next(m['delete'] for m in source['amendments'] if m['id']=='2026-22292')

def a_inserted(source):
    return next(m['insert'] for m in source['amendments'] if m['id']=='2026-22292')

def test_amendment_order_and_missing_predecessor(source):
    x=copy.deepcopy(source);x['amendments'].reverse()
    assert periods(x)==periods(source)
    x['amendments'][0]['delete'].append('99999999')
    with pytest.raises(ValueError,match='does not reconcile'):periods(x)

def test_qualified_interactions_are_not_blanket_zero(source):
    refs=interaction_codes(source['interaction']['text'])
    assert refs['vehicle']=='9903.94.02' and refs['parts']=='9903.94.06'
    assert '9903.82.02' in refs['all'] and '9903.82.26' in refs['all']
    assert '9903.04.66' in refs['all'] and '9903.03.12' not in refs['all']
    with pytest.raises(ValueError,match='qualified'):interaction_codes(source['interaction']['text'].replace('U.S. content','foreign content'))

def test_chapter98_is_authority_specific(source):
    policy=treatment(source['general_note']);assert policy['subchapter_xxiii_full_value']
    s122=(ROOT/'resources/legal_evidence/section122/interactions/2026-03824-page9347-ocr.txt').read_text()
    assert not treatment(s122)['subchapter_xxiii_full_value']
    assert treatment(s122)['repairs']==policy['repairs']==['98020040','98020050','98020060']
    with pytest.raises(ValueError,match='valuation'):treatment(s122.replace('less the cost or value','including the cost or value'))

def test_compiler_precision_model_independence_and_source_horizon():
    ps=['2208306075','2208306085','8537109120','8537109130']
    a=compile_rules('2026_rev_17',ps)
    assert compile_rules('2026_rev_17',list(reversed(ps))+ps)==a
    assert not a['coverage']
    assert a['supported_until']==audit_until()
    later=[r for r in a['rules'] if r['scope']['from']=='2026-09-15T00:01:00-04:00']
    assert {p for r in later for p in r['scope']['hts_exact']}=={'2208306075','8537109130'}
    assert 'authority_covered' not in str(later)  # these two actions become additive
    assert 'modeled_share' not in str(a['rules']) and 'assembly_credit' not in str(a['rules'])
    with pytest.raises(ValueError,match='Product not valid'):compile_rules('2026_rev_17',['9999999999'])
