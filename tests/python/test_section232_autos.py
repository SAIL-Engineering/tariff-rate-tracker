"""Automobile decisions must come from original scopes, not sector averages."""
import copy
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'src'))
from section232_autos import load_history, extract, compile_rules


@pytest.fixture(scope='module')
def latest():
    return extract(ROOT/'data/us_notes/chapter99_2026_rev_19.pdf',
                   ROOT/'data/hts_archives/hts_2026_rev_19.json', '2026_rev_19')


def test_original_annex_supplies_scopes_rates_and_exact_instants():
    h = load_history()
    assert h['vehicles']['from'] == '2025-04-03T00:01:00-04:00'
    assert h['parts']['from'] == '2025-05-03T00:01:00-04:00'
    assert len(h['vehicles']['prefixes']) == 17
    assert '87032301' in h['vehicles']['prefixes']
    assert '870321' not in h['vehicles']['prefixes']
    assert '8471' in h['parts']['prefixes']
    assert '4009120020' in h['parts']['prefixes']
    assert '40091200' not in h['parts']['prefixes']
    assert h['vehicles']['percent'] == h['parts']['percent'] == 25
    assert h['age_years'] == 25
    assert {d['country']:d['from'] for d in h['deals']} == {
        'United Kingdom':'2025-06-30T00:01:00-04:00',
        'Japan':'2025-09-16T00:01:00-04:00',
        'European Union':'2025-08-01T00:01:00-04:00',
        'South Korea':'2025-11-01T00:01:00-04:00',
        'Taiwan':'2026-05-01T00:01:00-04:00'}


def test_precise_original_membership_and_conditional_machine_use(latest):
    products = ['8703230190','8703210150','8471500150','4009120020','4009120050']
    f = compile_rules(latest, products, {'all':['2010','5700','5880','4120','1220','5800','5830'],
        'United Kingdom':['4120'],'Japan':['5880'],'European Union':['1220'],
        'South Korea':['5800'],'Taiwan':['5830']})
    assert f['coverage'] == []
    charged = [r for r in f['rules'] if r['action_id']=='s232_automobiles']
    assert all(r['scope']['hts_exact']==['8703230190'] for r in charged)
    parts = [r for r in f['rules'] if r['action_id']=='s232_automobile_parts']
    assert parts
    assert {p for r in parts for p in r['scope']['hts_exact']} == {'4009120020','8471500150'}
    assert all(set(r['scope']['hts_exact']) <= {'4009120020','8471500150'} for r in parts)
    assert 's232_auto_parts_use' in f['fact_definitions']
    assert 'metal_share' not in str(f) and 'assembly_credit' not in str(f)
    assert any('ftz' in str(r['when']) for r in parts)
    assert f['candidate_scope_source']['source_id']=='FR-2025-05930-auto-pdf'
    assert {'hts10':'8471500150','scope_code':'8471','scope_grain':'prefix'} in f['candidate_memberships']['s232_automobile_parts']
    assert {'hts10':'4009120020','scope_code':'4009120020','scope_grain':'exact_hts10'} in f['candidate_memberships']['s232_automobile_parts']
    assert all(r['hts10']!='4009120050' for r in f['candidate_memberships']['s232_automobile_parts'])


def test_changed_scope_or_claim_semantics_cannot_pass_as_reviewed(latest):
    for key in ('b','c','d','e','g','h'):
        changed = copy.deepcopy(latest)
        changed['clauses'][key] += ' Additional unreviewed legal condition.'
        with pytest.raises(ValueError, match='Unreviewed automobile'):
            compile_rules(changed, ['8703230190'], {'all':['2010']})


def test_original_specific_scope_never_broadens_to_hts8(latest):
    f = compile_rules(latest, ['4009120050'], {'all':['2010']})
    assert not [r for r in f['rules'] if r['action_id']=='s232_automobile_parts']


def test_country_heading_rate_change_requires_original_amendment_reconciliation(latest):
    changed = copy.deepcopy(latest)
    next(r for r in changed['headings'] if r['htsno']=='9903.94.43')['general']='18%'
    with pytest.raises(ValueError,match='Unreviewed automobile country duty expression'):
        compile_rules(changed,['8471500150'],{'all':['5880'],'Japan':['5880']})


def test_nonexistent_statistical_suffix_is_not_an_uncovered_product(latest):
    with pytest.raises(ValueError,match='not valid in the identified revision'):
        compile_rules(latest,['4009120040'],{'all':['2010']})
