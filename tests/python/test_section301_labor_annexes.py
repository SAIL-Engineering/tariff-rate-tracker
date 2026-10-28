import copy
import sys
from pathlib import Path
import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'src'))
import section301_labor as labor


def test_every_original_product_exemption_has_executable_scope_data():
    history=labor.load_history()
    assert 'product_exemptions' in history, 'The normal compiler still lacks the original product annexes'
    inventory=history['product_exemptions']
    assert {x['reporting_code'] for x in inventory}=={
        r['reporting_code'] for r in history['original_headings']
        if any(t in r['description'] for t in ('subdivision (c)','subdivision (d)','subdivision (e)','subdivision (j)'))}
    assert len({x['reporting_code'] for x in inventory})==28
    uk=next(x for x in inventory if x['reporting_code']=='9903.05.96')
    assert '8419200010' in uk['includes'] and '84192000' not in uk['includes']
    particular=[x for x in inventory if x['reporting_code']=='9903.05.87']
    assert len(particular)==16 and all(x['condition']=='article_description' for x in particular)
    assert all(x['condition_text'] and x['source_scope_sha256'] for x in inventory)


def test_native_omission_does_not_remove_an_original_published_annex_scope():
    h=labor.load_history()
    x=next(x for x in h['product_exemptions'] if x['reporting_code']=='9903.06.09')
    assert '70191324' in x['includes']
    discrepancy=next(x for x in h['annex_reconciliation'] if x['reporting_code']=='9903.06.09')
    assert len(discrepancy['missing_from_native'])==30 and not discrepancy['additional_in_native']
    assert discrepancy['decision']=='original_published_annex_retained'


def test_unknown_annex_prose_or_unconsumed_table_cannot_broaden_scope():
    from section301_labor_annexes import product_exemptions
    layout,published,_=labor.evidence();note,_=labor.clauses(layout,published)
    expected=product_exemptions(note)
    changed=copy.deepcopy(note);changed['d']=changed['d'].replace('civil aircraft','civil or military aircraft',1)
    with pytest.raises(ValueError,match='Unreviewed'):product_exemptions(changed)
    changed=copy.deepcopy(note);changed['j']+='\nOnly certain aircraft are covered\n'
    with pytest.raises(ValueError,match='table|Unreviewed|description'):product_exemptions(changed)
    changed=copy.deepcopy(note);changed['j']=changed['j'].replace('8419.20.0010','8419.20.0010 annotation',1)
    with pytest.raises(ValueError,match='table'):product_exemptions(changed)
    assert expected==product_exemptions(note)


def test_native_condition_change_cannot_be_ignored_because_hts_membership_is_unchanged(monkeypatch):
    original=labor.native_note
    def changed(raw,n):
        parsed=original(raw,n)
        if n==52 and 'j' in parsed:parsed['j']=parsed['j'].replace('Psyllium seed husks','Other seed husks',1)
        return parsed
    monkeypatch.setattr(labor,'native_note',changed)
    with pytest.raises(ValueError,match='condition conflict'):labor.load_history()
