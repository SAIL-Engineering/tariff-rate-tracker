import copy
import json
from pathlib import Path
import sys
import unittest
import tempfile
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))
from section232_copper import load_history, extract, matches, compile_rules,reconcile_note,codes_only


class CopperSources(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.h=load_history()
        cls.first=extract('2025_rev_17')
        cls.last=extract('2026_rev_4')
        cls.retired=extract('2026_rev_5')

    def test_original_and_native_scope_and_rates_reconcile(self):
        self.assertEqual(len(self.h['hts8']),80)
        self.assertEqual(self.h['rate'],.5)
        self.assertEqual(self.h['from_'],'2025-08-01T00:01:00-04:00')
        self.assertEqual(self.h['until'],'2026-04-06T00:01:00-04:00')
        self.assertEqual(self.first['reconciliation']['status'],'original_note36_reconciled')
        self.assertEqual(self.last['reconciliation']['status'],'original_note36_reconciled')

    def test_replaced_heading_is_not_reanimated(self):
        self.assertEqual(self.retired['reconciliation']['status'],'retired_note36_snapshot')
        self.assertEqual(self.retired['headings'],[])

    def test_native_product_precision_and_order_invariance(self):
        sample=['8544429090','8544491000','8544493080','7408113000']
        self.assertEqual(matches(self.h,sample),sorted(sample[:2]+sample[3:]))
        x=copy.deepcopy(self.h);x['hts8'].reverse()
        self.assertEqual(matches(x,sample[::-1]*2),matches(self.h,sample))

    def test_no_model_share_or_assembly_credit_in_rule_formulas(self):
        f=compile_rules(self.first,['7408113000'])
        text=json.dumps(f['rules'])
        self.assertNotIn('copper_share',text)
        self.assertNotIn('assembly_credit',text)
        self.assertIn('declared_copper_content_value',text)
        self.assertIn('insufficient_documentation',json.dumps(f['fact_definitions']))

    def test_unlisted_product_never_gets_a_copper_duty_or_empty_claim(self):
        f=compile_rules(self.first,['8544493080'])
        self.assertEqual(f['rules'],[])
        self.assertEqual(f['claim_definitions'],[])
        self.assertEqual(f['coverage'],[])

    def test_unrecognized_native_scope_or_semantics_cannot_be_accepted(self):
        x=copy.deepcopy(self.first);x['clauses']['a']+=' A new qualification applies.'
        with self.assertRaisesRegex(ValueError,'changed after extraction'):
            compile_rules(x,['7408113000'])

    def test_new_exception_or_extra_condition_cannot_be_discarded(self):
        for prefix in ['Except as provided in headings 9903.00.01, heading ',
                       'Except as provided in headings 9903.02.76 and an extra condition, heading ']:
            clauses=copy.deepcopy(self.first['clauses'])
            clauses['a']=prefix+clauses['a'][len('Heading '):]
            with self.assertRaisesRegex(ValueError,'Unreconciled copper exception'):
                reconcile_note(clauses,self.first['headings'],self.h)

    def test_unrecognized_editorial_text_cannot_hide_a_scope_condition(self):
        with self.assertRaisesRegex(ValueError,'Unparsed copper scope'):
            codes_only("[Compiler's note: a new conditional qualification.] 7408.11.30")

    def test_reappearing_future_heading_requires_new_legal_reconciliation(self):
        # A controlled later snapshot cannot resurrect an old heading while
        # inheriting the old action's terminated clock, even with identical text.
        revision='2026_rev_21'
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for folder in ['data/us_notes','data/hts_archives','config']:(root/folder).mkdir(parents=True,exist_ok=True)
            (root/f'data/us_notes/chapter99_{revision}.pdf').symlink_to(ROOT/f'data/us_notes/chapter99_{revision}.pdf')
            rows=json.loads((ROOT/f'data/hts_archives/hts_{revision}.json').read_bytes())+self.last['headings']
            (root/f'data/hts_archives/hts_{revision}.json').write_text(json.dumps(rows))
            (root/'config/revision_dates.csv').write_bytes((ROOT/'config/revision_dates.csv').read_bytes())
            with patch('section232_copper.ROOT',root):
                with self.assertRaisesRegex(ValueError,'after verified retirement'):
                    extract(revision)


if __name__=='__main__':unittest.main()
