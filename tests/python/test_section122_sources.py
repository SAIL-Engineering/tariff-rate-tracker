import sys
from pathlib import Path
import copy
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'src'))
from section122_sources import extract,product_rows
ROOT=Path(__file__).resolve().parents[2]

@pytest.fixture(scope='module')
def evidence():
    return extract(ROOT/'data/us_notes/chapter99_2026_rev_4.pdf',
                   ROOT/'data/hts_archives/hts_2026_rev_4.json','2026_rev_4')

def test_precision_and_conditions(evidence):
    rows=evidence['products']
    exact=[r for r in rows if r['scope_grain']=='exact_hts10']
    assert [r['scope_code'] for r in exact]==['8505110070']
    assert exact[0]['condition']=='none' and exact[0]['reporting_code']=='9903.03.03'
    assert not any(r['scope_code']=='85051100' for r in rows)
    assert sum(r['condition']=='article_description' for r in rows)==11
    assert all(r['condition_text'] for r in rows if r['condition']!='none')
    assert all(r['source_text_sha256'] and r['source_ref'] for r in rows)

def test_revision_rate_and_nonproduct_predicates(evidence):
    assert evidence['rate']==.1
    assert len(evidence['clauses'])==8
    by_id={r['id']:r['text'] for r in evidence['clauses']}
    assert 'U.S. content' in by_id['v']
    assert 'knock-down kits' in by_id['v']
    assert 'entered free of duty' in by_id['viii']
    assert 'value of repairs' in by_id['i']

def test_unparsed_scope_fails(evidence):
    clauses={r['id']:r['text'] for r in evidence['clauses']}
    clauses['ii']+='\n except additional qualifying articles'
    with pytest.raises(ValueError,match='Unparsed'):product_rows(clauses)

def test_new_statistical_suffix_is_never_truncated(evidence):
    clauses={r['id']:r['text'] for r in evidence['clauses']}
    clauses['ii']=clauses['ii'].replace('8505.11.0070','8505.11.0071')
    rows=product_rows(clauses)
    assert any(r['scope_code']=='8505110071' for r in rows)
    assert not any(r['scope_code']=='85051100' for r in rows)
