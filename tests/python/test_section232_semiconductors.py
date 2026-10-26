import copy
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'src'))
from section232_semiconductors import load_history, extract, compile_rules


class SemiconductorHistory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.history = load_history()
        cls.latest = extract(ROOT/'data/us_notes/chapter99_2026_rev_21.pdf',
            ROOT/'data/hts_archives/hts_2026_rev_21.json', '2026_rev_21')

    def test_original_amendments_supply_exact_instants_and_distinct_targets(self):
        periods = self.history['periods']
        self.assertEqual([p['from_'] for p in periods], [
            '2026-01-15T00:01:00-05:00', '2026-04-06T00:01:00-04:00',
            '2026-04-23T00:01:00-05:00', '2026-05-01T00:01:00-04:00',
            '2026-06-08T00:01:00-04:00'])
        self.assertIn('9903.81.94', periods[0]['target_reporting_codes'])
        self.assertNotIn('9903.81.94', periods[1]['target_reporting_codes'])
        self.assertNotIn('9903.82.18', periods[1]['target_reporting_codes'])
        self.assertIn('9903.82.18', periods[2]['target_reporting_codes'])
        self.assertNotIn('9903.94.66', periods[2]['target_reporting_codes'])
        self.assertIn('9903.94.66', periods[3]['target_reporting_codes'])
        self.assertIn('9903.82.26', periods[4]['target_reporting_codes'])
        # June Annex IV B reverses this only in 2028, outside this audit.
        self.assertEqual(periods[-1]['until'], '2026-10-23T00:00:00-04:00')
        for p in periods:
            self.assertIn('9903.01.77', p['target_reporting_codes'])
            self.assertIn('9903.01.84', p['target_reporting_codes'])

    def test_current_native_note_reconciles_but_cannot_price_backwards(self):
        fragment = compile_rules(self.latest, ['8471500150', '8471809000', '8473301180', '8542310000'])
        self.assertEqual(len(fragment['rules']), 45)
        jan = [r for r in fragment['relations'] if r['period_from'].startswith('2026-01-15')][0]
        june = [r for r in fragment['relations'] if r['period_from'].startswith('2026-06-08')][0]
        self.assertNotIn('9903.82.26', jan['target_reporting_codes'])
        self.assertIn('9903.82.26', june['target_reporting_codes'])
        for r in fragment['rules']:
            self.assertEqual(set(r['scope']['hts_exact']), {'8471500150', '8471809000', '8473301180'})
            self.assertTrue(r['scope']['until'])
        self.assertEqual(fragment['coverage'], [])

    def test_scope_precision_and_input_order_are_invariant(self):
        products = ['8471500150', '8473301180', '8542310000']
        self.assertEqual(compile_rules(self.latest, products),
                         compile_rules(self.latest, products[::-1]*2))

    def test_unreviewed_technical_valuation_and_stacking_grammar_fail(self):
        for clause in 'abcd':
            changed = copy.deepcopy(self.latest)
            changed['clauses'][clause] += ' An additional unreviewed condition applies.'
            with self.assertRaisesRegex(ValueError, 'Unreviewed semiconductor'):
                compile_rules(changed, ['8471500150'])
        changed = copy.deepcopy(self.latest)
        changed['headings'][0]['general'] = '27%'
        with self.assertRaisesRegex(ValueError, 'Unreviewed semiconductor'):
            compile_rules(changed, ['8471500150'])

    def test_ftz_is_an_executable_question_and_does_not_guess_a_rate(self):
        fragment = compile_rules(self.latest, ['8471500150'])
        self.assertIn('ieepa_ftz_entry', fragment['fact_definitions'])
        for r in fragment['rules']:
            self.assertEqual(r['formula']['op'], 'if')
            self.assertEqual(r['formula']['args'][0], {'fact': 'ieepa_ftz_entry'})
            self.assertIn('unresolved_source', r['formula']['args'][1])
        self.assertNotIn('metal_share', str(fragment))
        self.assertNotIn('assembly_credit', str(fragment))

    def test_pre_action_snapshot_has_no_false_semiconductor_exemption(self):
        first = extract(ROOT/'data/us_notes/chapter99_2026_basic.pdf',
            ROOT/'data/hts_archives/hts_2026_basic.json', '2026_basic')
        fragment = compile_rules(first, ['8471500150'])
        self.assertEqual(fragment['rules'][0]['scope']['from'], self.history['start'])
        self.assertTrue(all(r['scope']['from'] >= self.history['start'] for r in fragment['rules']))


if __name__ == '__main__':
    unittest.main()
