"""MHD vehicles/buses are separate actions from their parts and modeled shares."""
from pathlib import Path
import sys
import pytest

ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'src'))
from section232_mhd_vehicles import load_history,extract,compile_rules


def test_original_vehicle_scopes_rates_and_reporting_roles():
    h=load_history()
    assert len(h['scopes']['vehicles'])==25 and len(h['scopes']['buses'])==10
    assert h['rates']=={'vehicles':.25,'buses':.10}
    assert h['from_']=='2025-11-01T00:01:00-04:00'
    assert h['roles']==dict(vehicles='9903.74.01',buses='9903.74.02',non_us='9903.74.03',non_vehicle='9903.74.05',us='9903.74.06',vintage='9903.74.07')
    assert h['age_years']==25


def test_scope_precision_and_country_independence():
    x=extract('2026_rev_4');ps=['8705900080','8705900020','8702103100']
    assert set(ps)<=set(x['products'])
    f=compile_rules(x,ps)
    assert not f['coverage']
    assert all('countries' not in r['scope'] for r in f['rules'])
    v={p for r in f['rules'] if r['action_id']=='s232_mhd_vehicles' for p in r['scope']['hts_exact']}
    assert '8705900080' in v and '8705900020' not in v
    assert f['candidate_scope_matches']['vehicles']==[dict(hts10='8705900080',scope_code='8705900080',scope_grain='exact_hts10')]
    assert f['candidate_scope_matches']['buses']==[dict(hts10='8702103100',scope_code='87021031',scope_grain='prefix')]
    assert all('assembly_credit' not in str(r) and 'usmca_share' not in str(r) for r in f['rules'])


def test_native_qualifiers_and_duty_columns_are_reconciled():
    x=extract('2026_rev_10')
    assert x['reconciliation']=='original_vehicle_annex_and_amendments_reconciled'
    import copy
    bad=copy.deepcopy(x);bad['clauses']['d']+=' Another new condition applies.'
    with pytest.raises(ValueError):compile_rules(bad,[x['products'][0]])
