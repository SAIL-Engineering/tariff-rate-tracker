import copy,sys
from pathlib import Path
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'src'))
from section122_rules import load_history,interaction_rows,compile_rules,ROOT
from section122_sources import extract

@pytest.fixture(scope='module')
def history():return load_history()

@pytest.fixture(scope='module')
def source():return extract(ROOT/'data/us_notes/chapter99_2026_rev_4.pdf',ROOT/'data/hts_archives/hts_2026_rev_4.json','2026_rev_4')

def test_annex_windows_and_zero_heading(history):
 assert history['start']=='2026-02-24T00:01:00-05:00'
 assert history['end']=='2026-07-24T00:01:00-04:00'
 a,b,intermediate,c,d=history['periods']
 assert a['until']==b['from_']=='2026-04-06T00:01:00-04:00'
 assert b['until']==intermediate['from_']=='2026-04-23T00:01:00-05:00'
 assert intermediate['until']==c['from_']=='2026-05-01T00:01:00-04:00'
 assert c['until']==d['from_']=='2026-06-08T00:01:00-04:00'
 assert any(r['kind']=='steel' and '9903.81.92' in r['codes'] for r in a['rows'])
 assert any(r['kind']=='aluminum' and '9903.85.09' in r['codes'] for r in a['rows'])
 assert any(r['kind']=='whole' and '9903.82.02' in r['codes'] for r in d['rows'])
 assert any('9903.82.26' in r['codes'] for r in d['rows'])

def test_original_malformed_token_not_silently_repaired(history):
 before,after=history['periods'][2:4]
 assert not any('9903.94.66' in r['codes'] for r in before['rows'])
 assert any('9903.94.66' in r['codes'] for r in after['rows'])
 assert not any('9903.94.67' in r['codes'] for r in after['rows'])
 assert any('903.94.67' in r['malformed_references'] for r in after['rows'])

def test_unknown_clause_fails():
 with pytest.raises(ValueError,match='Unreviewed'):
  interaction_rows('(1) any newly designated articles in heading 9903.88.88')

def test_range_keeps_exact_headings():
 r=interaction_rows('(1) articles of aluminum provided for in headings 9903.82.02 and 9903.82.04–9903.82.06;')[0]
 assert r['codes']==['9903.82.02','9903.82.04','9903.82.05','9903.82.06']

def test_model_fields_and_duplicate_product_order_cannot_affect_compilation(source):
 a=compile_rules(source,['8505110070','7318158085'])
 b=copy.deepcopy(source);b['modeled_share']=.2;b['assembly_credit']=999
 assert compile_rules(b,['7318158085','8505110070','7318158085'])==a
 assert not a['coverage']
 assert 'authority_covered' in str(a['rules'])
 assert 'src/section232_note16_rules.py' in a['compiler_dependencies']

def test_later_note_does_not_rewrite_prior_interactions(source):
 x=copy.deepcopy(source)
 # Clause v is deliberately replaced by the independently reconstructed history.
 next(c for c in x['clauses'] if c['id']=='v')['text']='post-expiry phantom amendment'
 with pytest.raises(ValueError,match='snapshot interaction'):compile_rules(x,['7318158085'])
 x=copy.deepcopy(source)
 x['rate']=.12
 with pytest.raises(ValueError,match='rate amendment'):compile_rules(x,['7318158085'])

def test_unreviewed_claim_mutation_fails(source):
 x=copy.deepcopy(source);x['clauses'][0]['text']+=' Claim removes all duties.'
 with pytest.raises(ValueError,match='predicate'):compile_rules(x,['7318158085'])

def test_later_product_or_procedural_change_requires_legal_chronology(source):
 x=copy.deepcopy(source);x['products'][0]['condition_text']='A newly narrowed description'
 with pytest.raises(ValueError,match='product-exemption amendment'):compile_rules(x,['7318158085'])
 x=copy.deepcopy(source)
 next(h for h in x['headings'] if h['htsno']=='9903.03.10')['description']+=' New country exception.'
 with pytest.raises(ValueError,match='procedural-exemption amendment'):compile_rules(x,['7318158085'])
