import copy
from pathlib import Path
import re
import subprocess
import sys
import pytest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))
import ieepa_fentanyl_sources as p

@pytest.fixture(scope='module')
def current():
    return p.extract(ROOT/'data/us_notes/chapter99_2025_rev_27.pdf',
        ROOT/'data/hts_archives/hts_2025_rev_27.json','2025_rev_27')

def test_amendment_reconstructs_both_intervals(current):
    rows=[a for a in current['actions'] if a['ch99_code']=='9903.01.24']
    assert [(a['rate'],a['valid_from'],a['valid_until']) for a in rows]==[
        (.2,'2025-03-04T00:01:00-05:00','2025-11-10T00:01:00-05:00'),
        (.1,'2025-11-10T00:01:00-05:00','2026-02-24T00:00:00-05:00')]
    assert all(a['amendment_source_id']=='FR-2025-19825' for a in rows)
    assert all(a['country_names']==['China','Hong Kong'] for a in rows)
    assert all(a['native_duty_expression'].endswith('10%') for a in rows)

def test_conditional_penalty_cannot_be_an_ordinary_action(current):
    a={r['ch99_code']:r for r in current['actions']}
    assert a['9903.01.10']['rate']==.35
    assert a['9903.01.16']['entry_type']=='conditional_replacement'
    assert a['9903.01.16']['rate']==.4
    assert 'determined by' in a['9903.01.16']['source_description']
    assert 'in lieu of' in a['9903.01.16']['source_note']

def test_note_supplies_energy_origin_and_preserves_claim_valuation(current):
    a=next(a for a in current['actions'] if a['ch99_code']=='9903.01.13')
    assert 'Canada' not in a['source_description']
    assert a['country_names']==['Canada']
    assert '9802.00.80' in a['source_note'] and 'value of repairs' in a['source_note']
    assert len(a['source_note_sha256'])==64

def test_inception_is_notice_entry_time_not_publication(current):
    a=next(a for a in current['actions'] if a['ch99_code']=='9903.01.01')
    assert a['valid_from']=='2025-03-04T00:01:00-05:00'
    assert a['inception_source_id']=='FR-2025-03665'

def test_notice_replacement_conflict_fails(current):
    x=copy.deepcopy(current)
    x['actions']=[a for a in x['actions'] if a['ch99_code']!='9903.01.24' or a['rate']==.1]
    next(a for a in x['actions'] if a['ch99_code']=='9903.01.24')['rate']=.3
    with pytest.raises(ValueError,match='conflicts'):p.reconcile_rate_replacement(x)

def test_time_zone_conflict_is_not_silently_normalized():
    with pytest.raises(ValueError,match='Conflicting'):
        p.windows('on or after 12:01 a.m. eastern standard time on July 1, 2025')

def test_notes_are_bounded_in_the_correct_subchapter():
    text=subprocess.check_output(['pdftotext','-layout',str(ROOT/'data/us_notes/chapter99_2025_rev_3.pdf'),'-'],text=True)
    notes=p.extract_notes(text)
    assert set(notes)==set('abj kst u'.replace(' ',''))
    assert 'Mexico' in notes['a'] and '9903.01.20' in notes['s']
    with pytest.raises(ValueError):p.extract_notes(text.replace('SUBCHAPTER III','UNLOCATED SUBCHAPTER'))

def test_canada_ordinary_and_conditional_windows_come_from_distinct_sections(current):
    ordinary=[a for a in current['actions'] if a['country_names']==['Canada'] and a['entry_type']=='general']
    assert [(a['rate'],a['valid_from'],a['valid_until']) for a in ordinary]==[
        (.25,'2025-03-04T00:01:00-05:00','2025-08-01T00:01:00-04:00'),
        (.35,'2025-08-01T00:01:00-04:00','2026-02-24T00:00:00-05:00')]
    assert all(a['amendment_source_id']=='FR-2025-14999' for a in ordinary)
    conditional=next(a for a in current['actions'] if a['entry_type']=='conditional_replacement')
    assert conditional['valid_from']=='2025-08-01T00:01:00-04:00'
    assert 'Sec. 3. Transshipment' in conditional['amendment_clause']
    assert 'CBP' in conditional['amendment_clause']


def test_relief_commencement_uses_original_notice_and_presidential_order(current):
    for code in ('9903.01.04','9903.01.05','9903.01.14','9903.01.15'):
        a=next(a for a in current['actions'] if a['ch99_code']==code)
        assert a['valid_from']=='2025-03-07T00:01:00-05:00'
        assert len(a['inception_source_ids'])==2
    assert all(a['valid_from'] and a['valid_until'] for a in current['actions'])


def test_transit_loading_cutoff_is_not_its_entry_cutoff(current):
    a=next(a for a in current['actions'] if a['ch99_code']=='9903.01.23')
    assert a['valid_from']=='2025-02-04T00:01:00-05:00'
    assert a['valid_until']=='2025-03-07T00:01:00-05:00'
    assert 'February 1, 2025' in a['transit_condition']
    assert 'or in transit on the final mode' in a['transit_condition']


def test_collection_termination_has_independent_evidence_and_midnight_boundary(current):
    assert current['collection_ended_at']=='2026-02-24T00:00:00-05:00'
    for a in current['actions']:
        assert a['termination_source_ids']==['FR-2026-03832','CBP-CSMS-67834313']
        assert a['valid_until']<=current['collection_ended_at']
    broken=copy.deepcopy(current);broken['actions'][0]['valid_from']=None
    with pytest.raises(ValueError,match='commencement'):p.close_collection_windows(broken)
