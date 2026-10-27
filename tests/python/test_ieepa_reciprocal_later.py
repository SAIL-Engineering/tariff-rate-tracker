"""Original-source policy events, independent of chosen HTS/origin examples."""
from pathlib import Path
import sys
import re
import pytest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))


def test_continuation_reconstructs_heading_identity_across_note_renumbering():
    from ieepa_reciprocal_initial import initial_history
    from ieepa_reciprocal_later import suspension_chain
    h=initial_history();events,sources=suspension_chain(h)
    assert [r['until'] for r in events]==['2025-11-10T00:01:00-05:00','2026-11-10T00:01:00-05:00']
    assert [r['from_'] for r in events]==['2025-08-12T00:01:00-04:00','2025-11-10T00:01:00-05:00']
    assert {r['reporting_code'] for r in events}=={'9903.01.63'}
    assert len({r['note_locator'] for r in events})==2
    assert {s['id'] for s in sources}=={'FR-2025-15554','FR-2025-19826'}


def test_partner_inventory_reconciles_every_original_inserted_heading():
    from ieepa_reciprocal_august import load_august_country_policy
    from ieepa_reciprocal_later import partner_history
    h=partner_history(load_august_country_policy())
    assert len(h['country_amendments'])==3
    assert len(h['exemptions'])==12
    assert sum(len(x['reporting_codes']) for x in h['country_amendments'])==6
    floors={r['country_text']:r for r in h['country_amendments']}
    assert floors['South Korea']['from_']=='2025-11-14T00:01:00-05:00'
    assert floors['Switzerland']['reporting_codes']==['9903.02.82','9903.02.83']
    assert floors['Liechtenstein']['reporting_codes']==['9903.02.87','9903.02.88']
    by_code={r['reporting_code']:r for r in h['exemptions']}
    assert by_code['9903.02.76']['from_']=='2025-09-01T00:01:00-04:00'
    assert by_code['9903.96.02']['from_']=='2025-09-16T00:01:00-04:00'
    assert by_code['9903.02.76']['condition']=='civil_aircraft_gn6_excluding_unmanned'
    assert '40091200' in by_code['9903.02.76']['products']
    assert by_code['9903.02.75']['condition']=='article_description'
    assert by_code['9903.02.75']['products']==['33012951']
    assert by_code['9903.02.77']['condition']=='nonpatented_pharmaceutical_use'
    assert all(r['source_ids'] and r['prefix_sha256'] for r in h['exemptions'])


def test_legal_timezone_is_not_changed_to_summer_eastern_time():
    from ieepa_reciprocal_later import entry_instant
    assert entry_instant('12:01 a.m. eastern standard time on April 23, 2026')=='2026-04-23T00:01:00-05:00'


def test_two_operative_instants_cannot_be_silently_reduced_to_the_first():
    from ieepa_reciprocal_later import entry_instant
    with pytest.raises(ValueError,match='Ambiguous'):
        entry_instant('12:01 a.m. eastern time on September 1, 2025; 12:01 a.m. eastern time on September 2, 2025')


def test_partner_new_condition_requires_review_even_with_a_known_heading(monkeypatch):
    import ieepa_reciprocal_later as m
    from ieepa_reciprocal_august import load_august_country_policy
    original=m.source
    def changed(doc):
        text,s=original(doc)
        if doc=='2025-18660':
            changed_text=re.sub(r'criteria of\s+General Note 6 of HTSUS','criteria of General Note 6 of HTSUS and an additional unreviewed condition',text)
            assert changed_text!=text
            text=changed_text
        return text,s
    monkeypatch.setattr(m,'source',changed)
    with pytest.raises(ValueError,match='Unreviewed partner legal condition'):
        m.partner_history(load_august_country_policy())


def test_replacement_must_identify_its_original_country_predecessor(monkeypatch):
    import ieepa_reciprocal_later as m
    from ieepa_reciprocal_august import load_august_country_policy
    original=m.source
    def changed(doc):
        text,s=original(doc)
        if doc=='2025-21940':text=text.replace('Heading 9903.02.56 is terminated','Heading 9903.02.58 is terminated')
        return text,s
    monkeypatch.setattr(m,'source',changed)
    with pytest.raises(ValueError,match='replace one original country action'):
        m.partner_history(load_august_country_policy())


def test_country_and_product_input_order_cannot_select_the_policy():
    from ieepa_reciprocal_august import load_august_country_policy
    from ieepa_reciprocal_later import partner_history
    a=load_august_country_policy();b=dict(a,actions=list(reversed(a['actions'])))
    assert partner_history(a)==partner_history(b)


def test_named_later_sector_decisions_are_extracted_without_positive_rate_tests():
    from ieepa_reciprocal_august import load_august_country_policy
    from ieepa_reciprocal_later import partner_history,sector_links
    links=sector_links(partner_history(load_august_country_policy()))['links']
    mh=next(x for x in links if '9903.74.09' in x['codes'])
    assert mh['from_']=='2025-11-01T00:01:00-04:00'
    assert '9903.74.05' not in mh['codes']
    timber=next(x for x in links if '9903.76.01' in x['codes'])
    assert '9903.76.04' not in timber['codes']
    semi=next(x for x in links if x['priority'])
    assert semi['codes']==['9903.79.01']
    assert semi['reporting_code']=='9903.01.33'
    assert semi['replaces_reporting_code']=='9903.01.32'
    assert all(x['source_clause_sha256'] and x['source_ids'] for x in links)


def test_all_typed_legal_windows_supply_boundaries_without_a_manual_date_list():
    from ieepa_reciprocal_later import legal_instants
    policy={'transit_until':'2025-10-05T00:01:00-04:00','new_action':{'from_':'2025-09-01T00:01:00-04:00'},
        'metadata':{'publication_date':'2025-09-25T00:00:00-04:00'}}
    assert legal_instants(policy)=={'2025-10-05T00:01:00-04:00','2025-09-01T00:01:00-04:00'}
    with pytest.raises(ValueError,match='legal instant'):
        legal_instants({'new_action':{'valid_until':'not a date'}})
