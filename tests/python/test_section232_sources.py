import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest
import tempfile
import hashlib

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))
from section232_sources import extract, extract_note16, c_references, matches
from section232_note16_rules import compile_note16


class Note16Sources(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.latest = extract(ROOT/'data/us_notes/chapter99_2026_rev_21.pdf',
            ROOT/'data/hts_archives/hts_2026_rev_21.json','2026_rev_21')
        cls.first = extract(ROOT/'data/us_notes/chapter99_2026_rev_5.pdf',
            ROOT/'data/hts_archives/hts_2026_rev_5.json','2026_rev_5')
        cls.text = subprocess.check_output(['pdftotext','-layout',str(ROOT/'data/us_notes/chapter99_2026_rev_21.pdf'),'-'],text=True)

    def test_bounded_exact_grains_and_multiple_memberships(self):
        rows = matches(self.latest,['7308200035','7308200036','7616995160','7616995161','7202115000'])
        self.assertEqual({r['metal'] for r in rows if r['hts10']=='7308200035'}, {'aluminum','steel'})
        self.assertEqual({r['metal'] for r in rows if r['hts10']=='7308200036'}, {'steel'})
        self.assertEqual({r['list_id'] for r in rows if r['hts10']=='7616995160'}, {'i'})
        self.assertFalse(any(r['hts10'] in ('7616995161','7202115000') for r in rows))

    def test_snapshot_removal_and_addition_not_union(self):
        # Source snapshots independently determine membership; no carry-forward
        # of the old aggregate/static CSV. Mobile-equipment list added later.
        self.assertEqual(len(self.first['lists']),10)
        self.assertEqual(len(self.latest['lists']),11)
        old = {r['list_id'] for r in matches(self.first,['8427104000'])}
        new = {r['list_id'] for r in matches(self.latest,['8427104000'])}
        self.assertNotIn('xi',old)
        self.assertEqual(new,{'xi'})

    def test_lists_not_truncated_and_clauses_not_roman_subsections(self):
        self.assertEqual([c['id'] for c in self.latest['clauses']],list('abcdefghijk'))
        self.assertEqual(len(self.latest['lists'][6]['includes']),242)
        self.assertIn('9802.00.60',self.latest['clauses'][1]['text'])
        self.assertIn('aggregate weight',' '.join(self.latest['clauses'][2]['text'].split()))
        self.assertEqual(len(self.latest['headings']),26)

    def test_tier_rates_and_references_come_from_heading(self):
        tiers=self.latest['ordinary_tiers']
        self.assertEqual([t['rate'] for t in tiers],[.5,.25,.15])
        self.assertEqual(tiers[-1]['formula_kind'],'column1_floor')
        self.assertIn('xi',tiers[1]['list_ids'])
        self.assertEqual(c_references('subdivisions (c)(ii), (iv), (vi)–(viii) and (xi)'),
                         ['ii','iv','vi','vii','viii','xi'])

    def test_unrecognized_layout_and_incomplete_table_fail(self):
        with self.assertRaises(ValueError):
            extract_note16(self.text.replace('7616.99.5160','unparsed scope',1))
        with self.assertRaises(ValueError):
            extract_note16(self.text.replace('(xi)      Derivative steel articles:', '(xii)     Derivative steel articles:',1))

    def test_source_order_and_duplicate_products_do_not_change_membership(self):
        products=['7308200035','7616995160','8427104000']
        other=copy.deepcopy(self.latest);other['lists'].reverse()
        for scope in other['lists']:scope['includes'].reverse()
        self.assertEqual(matches(self.latest,products),matches(other,products[::-1]*2))

    def test_wrong_revision_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'header'):
            extract(ROOT/'data/us_notes/chapter99_2026_rev_21.pdf',
                ROOT/'data/hts_archives/hts_2026_rev_21.json','2026_rev_20')

    def test_historical_parameters_and_retroactive_heading(self):
        self.assertEqual(self.first['parameters']['domestic'][0]['minimum_fraction'],.95)
        self.assertEqual(self.latest['parameters']['domestic'][0]['minimum_fraction'],.85)
        self.assertFalse(self.first['amendments'][0]['native_heading_present'])
        self.assertIn('9903.82.01',{h['code'] for h in self.first['headings']})
        self.assertEqual(self.first['amendments'][0]['valid_from'],'2026-04-06T00:01:00-04:00')
        self.assertEqual({h['code'] for h in self.latest['external_headings']},{'9903.85.67','9903.85.68'})

    def test_compiler_cannot_ignore_new_legal_predicates(self):
        jurisdictions=dict(all=['5700'],uk=[],russia=[],non_ntr=[],usmca=[],xi_partner=[])
        altered=copy.deepcopy(self.latest)
        altered['clauses'][3]['text']+=' An additional unreviewed qualification applies.'
        with self.assertRaisesRegex(ValueError,'Unreviewed legal predicate'):
            compile_note16(altered,['7318158085'],jurisdictions)

    def test_compiler_uses_source_rates_and_is_order_invariant(self):
        jurisdictions=dict(all=['5700'],uk=[],russia=[],non_ntr=[],usmca=[],xi_partner=[])
        altered=copy.deepcopy(self.latest)
        for h in altered['headings']:
            if h['code']=='9903.82.02':h['rate']=.271
        compiled=compile_note16(altered,['7318158085'],jurisdictions)
        rules=[r for r in compiled['rules'] if r['reporting_codes']==['9903.82.02']]
        self.assertEqual(rules[0]['formula']['args'][1],{'value':.271})
        altered['headings'].reverse();altered['lists'].reverse()
        self.assertEqual(compiled,compile_note16(altered,['7318158085']*2,jurisdictions))

    def test_empty_product_match_does_not_register_an_empty_claim(self):
        jurisdictions=dict(all=['5700'],uk=[],russia=[],non_ntr=[],usmca=[],xi_partner=[])
        compiled=compile_note16(self.latest,['0106199120'],jurisdictions)
        self.assertEqual(compiled['rules'],[])
        self.assertEqual(compiled['claim_definitions'],[])
        self.assertEqual(compiled['coverage'],[])  # No all232 absence inference.

    def test_native_free_benchmark_is_not_an_importer_or_model_assumption(self):
        jurisdictions=dict(all=['5700'],uk=[],russia=[],non_ntr=[],usmca=[],xi_partner=[])
        compiled=compile_note16(self.latest,['8427104090'],jurisdictions)
        decision,=compiled['column1_reference_decisions']
        self.assertEqual(decision['status'],'source_zero')
        self.assertEqual(decision['source']['expression'],'Free')
        self.assertTrue('8427104090'.startswith(decision['source']['source_code']))
        self.assertNotIn('column1_duty_amount',json.dumps(compiled['rules']))

    def test_changed_nonfree_or_missing_native_benchmark_never_defaults_to_zero(self):
        jurisdictions=dict(all=['5700'],uk=[],russia=[],non_ntr=[],usmca=[],xi_partner=[])
        reference=compile_note16(self.latest,['8427104090'],jurisdictions)['column1_reference_decisions'][0]
        native_source=next(s for s in self.latest['sources'] if Path(s['path']).suffix=='.json')
        original=json.loads(Path(native_source['path']).read_bytes())
        # Controlled source-version changes test extraction/ownership and no-zero
        # behavior. They are not assertions that either changed rate is lawful.
        for expression in ('5%','See an unresolved authority'):
            with tempfile.TemporaryDirectory() as tmp:
                rows=copy.deepcopy(original)
                rows[reference['source']['source_row_index']]['general']=expression
                raw=json.dumps(rows).encode();path=Path(tmp)/'controlled-native.json';path.write_bytes(raw)
                x=copy.deepcopy(self.latest)
                source=next(s for s in x['sources'] if Path(s['path']).suffix=='.json')
                source.update(path=str(path),sha256=hashlib.sha256(raw).hexdigest())
                compiled=compile_note16(x,['8427104090'],jurisdictions)
                decision,=compiled['column1_reference_decisions']
                self.assertEqual(decision['status'],'requires_actual_column1_benchmark')
                self.assertIn('column1_duty_amount',json.dumps(compiled['rules']))
                source['sha256']='0'*64
                with self.assertRaisesRegex(ValueError,'benchmark source changed'):
                    compile_note16(x,['8427104090'],jurisdictions)


if __name__ == '__main__':
    unittest.main()
