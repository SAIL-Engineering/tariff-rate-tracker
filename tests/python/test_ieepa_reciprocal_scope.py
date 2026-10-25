import copy,json,sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'src'))
from ieepa_reciprocal_history import history,active_rows,reconcile_native,enumeration
from ieepa_reciprocal_sources import extract,matches,product_scope,ROOT

@pytest.fixture(scope='module')
def h():return history()

def covered(h,code,at,condition='none'):
    return [r for r in active_rows(h,at) if code.startswith(r['scope_code']) and r['condition']==condition]

@pytest.mark.parametrize('at,yes', [('2025-04-05T00:00:59-04:00',False),('2025-04-05T00:01:00-04:00',True),
    ('2026-02-23T23:59:59-05:00',True),('2026-02-24T00:00:00-05:00',False)])
def test_electronics_retroactivity_and_collection_end(h,at,yes):
    assert bool(covered(h,'8471300100',at))==yes

@pytest.mark.parametrize('code,before,after',[
    ('7407101500','2025-08-01T00:00:59-04:00','2025-08-01T00:01:00-04:00'),
    ('3907300000','2025-09-08T00:00:59-04:00','2025-09-08T00:01:00-04:00'),
    ('4407110000','2025-10-14T00:00:59-04:00','2025-10-14T00:01:00-04:00')])
def test_exact_removal_windows(h,code,before,after):
    assert covered(h,code,before) and not covered(h,code,after)

def test_timber_operative_annex_resolves_qualifier_without_invented_claim(h):
    assert len(h['wood_retained_codes'])==12
    assert covered(h,'4403420000','2025-10-14T00:01:00-04:00')
    assert not covered(h,'4412310600','2025-10-14T00:01:00-04:00')
    deleted=[r for r in h['products'] if r.get('termination_source_id')=='FR-2025-19482-ANNEX']
    assert len(deleted)==158 and all(r['scope_code'].startswith('44') for r in deleted)

def test_exact_hts10_never_broadens_to_adjacent_magnet(h):
    before='2025-09-08T00:00:59-04:00';after='2025-09-08T00:01:00-04:00'
    assert not covered(h,'8505110070',before)
    assert covered(h,'8505110070',after)
    assert not covered(h,'8505110030',after)

def test_agricultural_unconditional_vs_description(h):
    at='2025-11-13T00:01:00-05:00'
    assert not covered(h,'0803900035','2025-11-13T00:00:59-05:00') and covered(h,'0803900035',at)
    assert not covered(h,'1905901070',at)
    x=covered(h,'1905901070',at,'article_description')
    assert len(x)==1 and 'religious purposes only' in x[0]['condition_text'] and x[0]['reporting_code']=='9903.02.78'
    assert len([r for r in h['products'] if r['condition']=='article_description'])==11

def test_aligned_partner_annex_and_informational_chapters_not_universal(h):
    for code in ['0106199120','4909004020','9701910000','9801001010']:
        assert not covered(h,code,'2025-11-20T12:00:00-05:00')

def test_explicit_printed_matter_is_preserved(h):
    assert covered(h,'4901990093','2025-11-20T12:00:00-05:00')

def test_early_snapshot_gets_original_retroactive_electronics(h):
    x=extract(ROOT/'data/us_notes/chapter99_2025_rev_7.pdf',ROOT/'data/hts_archives/hts_2025_rev_7.json','2025_rev_7')
    assert not matches(x,['8471300100'])
    assert covered(x['history'],'8471300100','2025-04-05T00:01:00-04:00')
    assert x['reconciliation']['status']=='reconciled_original_annex'
    bad=copy.deepcopy(x);bad['products'].append(dict(scope_code='01061991',condition='none'))
    with pytest.raises(ValueError,match='every verified'):reconcile_native(bad,h)

def test_strict_enumeration_and_no_silent_unknown_grammar():
    assert enumeration('8505.11.0070\n8471\n')==['8471','8505110070']
    with pytest.raises(ValueError,match='Unparsed'):enumeration('8505.11.0070 except goods made from X')
    with pytest.raises(ValueError,match='exact|Exact'):matches({'products':[]},['85051100'])
    with pytest.raises(ValueError,match='timezone'):active_rows(history(),'2025-09-09T12:00:00')

def test_scope_product_order_and_duplicates_do_not_change_decisions(h):
    x={'products':active_rows(h,'2025-11-14T12:00:00-05:00')}
    products=['8505110070','8471300100','1905901070']
    assert matches(x,products)==matches(x,list(reversed(products))+products)
