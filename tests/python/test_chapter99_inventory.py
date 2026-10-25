"""Inventory regressions prevent omitted provisions and false legal coverage."""
import copy
import importlib.util
import json
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src'))


def api():
    path = ROOT / 'src/chapter99_inventory.py'
    assert path.exists(), 'Chapter 99 inventory compiler is missing'
    spec = importlib.util.spec_from_file_location('chapter99_inventory', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


TEXT = '''Harmonized Tariff Schedule of the United States Revision 21 (2026)
SUBCHAPTER II
Compiler's Note: The provisions of this subchapter have expired.
9902.01.01 Frozen corn Free On or before 12/31/2020
SUBCHAPTER III
U.S. Notes
1. The duties in this subchapter are cumulative unless otherwise specified.
2. (a) Articles of China in heading 9903.01.01, as provided in 8501.10.4060.
   (b) An exception refers to heading 9903.01.99.
Heading/ Stat.
9903.01.01 Articles the product of China
9903.92 Cargo handling equipment The duty provided in the applicable subheading + 25%
9903.92.10 Other cranes
9999.00.01 Unreviewed action
'''
ROWS = [
    dict(htsno='9902.01.01', indent='0', description='Frozen corn', general='Free'),
    dict(htsno='9903.01.01', indent='0', description='Articles of China as provided in U.S. note 2(a)', general='20%'),
    dict(htsno='9903.92', indent='0', description='Cranes', general='The duty provided in the applicable subheading + 25%'),
    dict(htsno='9903.92.10', indent='1', description='Other cranes', general=''),
    dict(htsno='9999.00.01', indent='0', description='Unreviewed action', general=''),
]


def test_every_native_provision_and_note_only_reference_survives():
    x = api().extract_inventory(TEXT, ROWS, '2026_rev_21')
    rows = {r['reporting_code']: r for r in x['provisions']}
    assert set(rows) == {'9902.01.01', '9903.01.01', '9903.01.99', '9903.92', '9903.92.10', '9999.00.01'}
    assert rows['9903.01.99']['presence'] == 'note_reference_only'
    assert rows['9903.01.99']['questions']
    unknown = rows['9999.00.01']
    assert unknown['status'] == 'unresolved_source'
    assert unknown['authority'] is None
    assert unknown['legal_intervals'] == []
    assert set(unknown['unresolved_aspects']) == {'authority', 'scope', 'origin', 'reporting_role', 'legal_window', 'valuation', 'interactions'}
    assert all('9999.00.01' in q['question'] for q in unknown['questions'])


def test_snapshot_expiry_and_inherited_expression_do_not_become_a_duty():
    rows = {r['reporting_code']: r for r in api().extract_inventory(TEXT, ROWS, '2026_rev_21')['provisions']}
    expired = rows['9902.01.01']
    assert expired['snapshot_status'] == 'source_declares_expired'
    assert expired['status'] == 'unresolved_source'
    crane = rows['9903.92.10']
    assert crane['duty_expression'] == 'The duty provided in the applicable subheading + 25%'
    assert crane['expression_source_code'] == '9903.92'
    assert crane['legal_intervals'] == []
    assert 'amount' not in crane


def test_reference_in_expired_subchapter_does_not_expire_an_active_heading():
    text=TEXT.replace("have expired.","have expired. A reference also mentions 9903.01.01.")
    r=next(r for r in api().extract_inventory(text,ROWS,'2026_rev_21')['provisions'] if r['reporting_code']=='9903.01.01')
    assert r['snapshot_status']=='not_determined'


def test_note_references_retain_exact_product_precision_and_full_evidence():
    x = api().extract_inventory(TEXT, ROWS, '2026_rev_21')
    r = next(r for r in x['provisions'] if r['reporting_code'] == '9903.01.01')
    note_ids = {n['id'] for n in r['note_evidence']}
    assert any(n['number'] == '2' and '8501.10.4060' in n['text'] for n in x['notes'] if n['id'] in note_ids)
    note = next(n for n in x['notes'] if n['id'] == 'III:2')
    assert note['referenced_product_codes'] == ['8501104060']
    assert '85011040' not in note['referenced_product_codes']
    assert r['referenced_product_codes'] == []  # a note's references are not this heading's legal scope
    assert r['reference_membership_is_discovery_only'] is True
    assert all(len(n['sha256']) == 64 for n in r['note_evidence'])


def test_conflicting_duplicate_and_json_pdf_omission_fail():
    with pytest.raises(ValueError, match='Conflicting'):
        api().extract_inventory(TEXT, ROWS + [dict(ROWS[1], general='30%')], '2026_rev_21')
    with pytest.raises(ValueError, match='absent from PDF'):
        api().extract_inventory(TEXT, ROWS + [dict(htsno='9999.00.02', description='Missing', general='10%')], '2026_rev_21')
    with pytest.raises(ValueError, match='revision'):
        api().extract_inventory(TEXT, ROWS, '2025_rev_21')


def fragment():
    return dict(contract_version='sail.shipment-rule-fragment/v1', id='synthetic', supported_from='2026-01-01T00:00:00-05:00',
        supported_until='2026-10-23T00:00:00-04:00', coverage=[], sources=[dict(id='s', status='verified', sha256='a'*64)],
        fact_definitions={'use': dict(type='boolean')}, rules=[dict(id='rule', action_id='action', authority='section_301',
            kind='duty', verification='verified', source_ids=['s'], reporting_codes=['9903.92.10'],
            scope=dict(hts_exact=['8501104060'], countries=['5700'], **{'from':'2026-06-01T00:01:00-04:00','until':'2026-07-01T00:01:00-04:00'}),
            when={'fact':'use'}, formula={'op':'multiply','args':[{'value':.25},{'fact':'customs_value'}]})])


def test_rule_links_preserve_legal_scope_and_condition_without_granting_coverage():
    f = fragment()
    x = api().extract_inventory(TEXT, ROWS, '2026_rev_21', fragments=[f])
    r = next(r for r in x['provisions'] if r['reporting_code'] == '9903.92.10')
    assert r['status'] == 'linked_rules_partial'
    assert r['authority'] == 'section_301'
    assert r['legal_intervals'] == [{'from':'2026-06-01T00:01:00-04:00','until':'2026-07-01T00:01:00-04:00'}]
    assert r['rule_links'][0]['scope']['hts_exact'] == ['8501104060']
    assert r['rule_links'][0]['when'] == {'fact':'use'}
    assert r['rule_links'][0]['formula']['op'] == 'multiply'
    assert r['unresolved_aspects'] == ['inventory_completeness']
    assert x['coverage'] == []
    assert api().extract_inventory(TEXT, ROWS, '2026_rev_21', fragments=[f,f]) == x


def test_unverified_and_conflicting_rule_definitions_cannot_be_linked_as_verified():
    bad = fragment();bad['sources'][0]['status'] = 'unresolved_source'
    with pytest.raises(ValueError, match='unverified'):
        api().extract_inventory(TEXT, ROWS, '2026_rev_21', fragments=[bad])
    second=fragment();second['rules'][0]['formula']={'value':0}
    with pytest.raises(ValueError, match='Conflicting'):
        api().extract_inventory(TEXT, ROWS, '2026_rev_21', fragments=[fragment(),second])


def test_linked_original_action_absent_from_snapshot_is_not_discarded():
    f=fragment();f['rules'][0]['reporting_codes']=['9903.01.98']
    r=next(r for r in api().extract_inventory(TEXT, ROWS, '2026_rev_21', fragments=[f])['provisions'] if r['reporting_code']=='9903.01.98')
    assert r['presence']=='rule_source_only'
    assert r['rule_links'][0]['rule_id']=='rule'
    assert r['status']=='linked_rules_partial'


def test_declared_uncompiled_paths_keep_their_exact_rule_and_question():
    f=fragment();f['rules'][0]['formula']={'unresolved_source':'ftz_admission_instruction_history'}
    r=next(r for r in api().extract_inventory(TEXT,ROWS,'2026_rev_21',fragments=[f])['provisions'] if r['reporting_code']=='9903.92.10')
    assert 'executable_gap' in r['unresolved_aspects']
    assert any(q.get('rule_id')=='rule' and 'ftz_admission_instruction_history' in q['question'] for q in r['questions'])


def test_actual_revision_has_every_native_code_and_expired_provisions():
    m=api();pdf=ROOT/'data/us_notes/chapter99_2026_rev_21.pdf';hts=ROOT/'data/hts_archives/hts_2026_rev_21.json'
    x=m.build_inventory(pdf,hts,'2026_rev_21')
    native={r['htsno'] for r in json.loads(hts.read_bytes()) if r.get('htsno','').startswith('99')}
    indexed={r['reporting_code']:r for r in x['provisions']}
    assert native <= indexed.keys()
    assert indexed['9902.01.01']['snapshot_status']=='source_declares_expired'
    assert indexed['9901.00.50']['snapshot_status']=='source_declares_expired'
    assert len(x['sources'])==2
    assert x['coverage']==[]


def test_relative_fragment_evidence_is_pinned_to_its_directory_and_declared_source(tmp_path):
    m=api();evidence=tmp_path/'evidence.txt';evidence.write_text('primary test evidence')
    f=fragment();digest=m.sha(evidence.read_bytes());f['sources'][0]['sha256']=digest
    f['source_artifacts']=[dict(source_id='s',path='evidence.txt',sha256=digest)]
    path=tmp_path/'rules.json';path.write_text(json.dumps(f))
    args=(ROOT/'data/us_notes/chapter99_2026_rev_21.pdf',ROOT/'data/hts_archives/hts_2026_rev_21.json','2026_rev_21',[path])
    assert m.build_inventory(*args)['counts']['linked_provisions']==1
    f['source_artifacts']=[];path.write_text(json.dumps(f))
    with pytest.raises(ValueError,match='Missing.*evidence'):m.build_inventory(*args)
    f['source_artifacts']=[dict(source_id='s',path='evidence.txt',sha256=digest)]
    f['sources'][0]['sha256']='a'*64;path.write_text(json.dumps(f))
    with pytest.raises(ValueError,match='source hash mismatch'):m.build_inventory(*args)
    f['sources'][0]['sha256']=digest;path.write_text(json.dumps(f));evidence.write_text('mutated')
    with pytest.raises(ValueError,match='source hash mismatch'):m.build_inventory(*args)
