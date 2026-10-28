import copy
import json
from pathlib import Path
import sys
import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'src'))
import section301_labor as labor


@pytest.fixture(scope='module')
def history():
    return labor.load_history()


def test_complete_original_heading_and_action_inventory(history):
    assert len(history['original_headings']) == 101
    assert len(history['actions']) == 60
    assert sum(len(a['headings']) for a in history['actions']) == 65
    assert history['from_'] == '2026-07-24T00:01:00-04:00'
    assert history['amendment_from'] == '2026-07-31T00:01:00-04:00'
    assert len(history['periods'][0]['items']) == 7
    assert len(history['periods'][1]['items']) == 8


def test_source_named_zero_payable_and_excluded_metal_heads(history):
    metal=history['periods'][0]['items'][0]
    assert '9903.82.02' in metal['reporting_codes']
    assert '9903.82.26' in metal['reporting_codes']
    assert '9903.82.01' not in metal['reporting_codes']
    assert '9903.82.03' not in metal['reporting_codes']
    assert history['periods'][0]['items'][1]['qualified_codes'] == {'9903.94.02':'s232_auto_approved_us_content'}
    assert history['periods'][0]['items'][2]['qualified_codes'] == {'9903.94.06':'s232_usmca_auto_parts_not_kits'}


def test_source_identity_is_order_and_duplicate_independent():
    meta=json.loads((labor.EVIDENCE/'sources.json').read_bytes())
    expected=labor.evidence(meta)
    meta['sources']=list(reversed(meta['sources']))+[copy.deepcopy(meta['sources'][0])]
    assert labor.evidence(meta)==expected
    meta['sources'][0]['sha256']='0'*64
    with pytest.raises(ValueError,match='source changed'):
        labor.evidence(meta)


def test_unreviewed_clause_or_missing_heading_cannot_pass(history):
    layout,publication,_=labor.evidence()
    with pytest.raises(ValueError,match='interaction disagreement'):
        labor.clauses(layout,publication.replace('9903.82.26','9903.82.25'))
    changed=layout.replace('9903.05.20','9903.05.21',1)
    with pytest.raises(ValueError):labor.original_headings(changed)
    with pytest.raises(ValueError,match='Unaccounted'):
        labor.interaction_inventory('(1) articles in 9903.82.02; (3) articles in 9903.79.01')


def test_no_aggregate_price_or_full_coverage_attestation(history):
    jurisdictions={a['country_text']:['4280'] for a in history['actions']}
    fragment=labor.compile_rules('2026_rev_19',['7304313000'],jurisdictions)
    assert not fragment['coverage']
    assert all(r['formula']=={'value':0} for r in fragment['rules'] if r.get('reporting_only'))
    assert all('unresolved_source' in r['formula'] for r in fragment['rules'] if not r.get('reporting_only'))
    assert all(not r['reporting_codes'] for r in fragment['rules'] if not r.get('reporting_only'))
    serialized=json.dumps(fragment['rules'])
    assert 'positive_duty": true' not in serialized
    assert 'modeled_' not in serialized
    with pytest.raises(ValueError,match='origin'):
        labor.compile_rules('2026_rev_19',['7304313000'],{})
