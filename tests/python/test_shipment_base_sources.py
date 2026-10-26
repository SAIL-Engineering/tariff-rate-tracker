import copy
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))
from shipment_base_sources import extract_rows, extract


def row(code,indent,general='',other='',description='Test article'):
    return dict(htsno=code,indent=str(indent),general=general,other=other,
                description=description,special='',footnotes=[])


class ShipmentBaseSources(unittest.TestCase):
    def test_special_classifications_are_retained_separately_from_ordinary_base_rates(self):
        x=extract_rows([row('9801.00.10',0,'Free',description='Returned articles, if qualifying'),
            row('9801.00.10.10',1),row('9802.00.40',0,'A duty upon the value of the repairs')])
        self.assertEqual(x['products'],[])
        special={r['hts10']:r for r in x['special_classifications']}
        self.assertEqual(set(special),{'9801001010','9802004000'})
        self.assertEqual(special['9801001010']['general']['expression'],'Free')
        self.assertEqual(special['9801001010']['source_role'],'conditional_special_classification')
        self.assertEqual(special['9802004000']['native_grain'],8)

    def test_raw_compound_expression_and_owning_parent_are_preserved(self):
        rows=[row('7318',0),row('7318.15',1),row('7318.15.80',2,'4.5% + $1/kg','40%'),
              row('7318.15.80.85',3)]
        p=extract_rows(rows)['products'][0]
        self.assertEqual(p['hts10'],'7318158085')
        self.assertEqual(p['general']['expression'],'4.5% + $1/kg')
        self.assertEqual(p['general']['source_code'],'73181580')
        self.assertEqual(p['column2']['expression'],'40%')
        self.assertEqual(p['status'],'source_extracted')
        self.assertEqual([n['code'] for n in p['classification_path']],['7318','731815','73181580','7318158085'])
        self.assertTrue(all(n['description']=='Test article' for n in p['classification_path']))
        self.assertNotIn('base_rate',p)

    def test_every_new_branch_clears_obsolete_rate_ancestors(self):
        rows=[row('7318',0),row('7318.15',1),row('7318.15.80',2,'Free','40%'),
              row('7318.15.80.85',3),row('7318.16',1),row('7318.16.00',2),row('7318.16.00.20',3)]
        p={p['hts10']:p for p in extract_rows(rows)['products']}['7318160020']
        self.assertIsNone(p['general']['expression'])
        self.assertIsNone(p['column2']['expression'])
        self.assertEqual(p['status'],'unresolved_source')
        self.assertIn('missing_general_expression',p['source_errors'])

    def test_foreign_code_ancestor_cannot_supply_a_rate(self):
        rows=[row('7318',0),row('7318.15.80',1,'Free'),row('7318.16.00.20',2)]
        p=extract_rows(rows)['products'][-1]
        self.assertIsNone(p['general']['expression'])
        self.assertIn('unrelated_general_ancestor',p['source_errors'])
        self.assertEqual(p['general']['rejected_source_code'],'73181580')

    def test_leaf_eight_digit_identity_does_not_expand_a_parent(self):
        rows=[row('7318',0),row('7318.15.80',1,'Free'),row('7318.15.80.85',2),
              row('7318.16.00',1,'2%')]
        p={p['hts10']:p for p in extract_rows(rows)['products']}
        self.assertEqual(set(p),{'7318158085','7318160000'})
        self.assertEqual(p['7318160000']['native_grain'],8)
        self.assertEqual(p['7318160000']['native_code'],'73181600')
        self.assertEqual(p['7318158085']['native_grain'],10)

    def test_unknown_expression_is_retained_without_numeric_fallback(self):
        text='The rate applicable to each garment if separately entered'
        p=extract_rows([row('6104.29.20',0,text),row('6104.29.20.10',1)])['products'][0]
        self.assertEqual(p['general']['expression'],text)
        self.assertNotIn('rate',p['general'])

    def test_conflicting_duplicate_and_invalid_indent_fail(self):
        with self.assertRaisesRegex(ValueError,'Conflicting'):
            extract_rows([row('7318.15.80.85',0,'Free'),row('7318.15.80.85',0,'25%')])
        bad=row('7318.15.80.85',0,'Free');bad['indent']='unknown'
        with self.assertRaisesRegex(ValueError,'indent'):
            extract_rows([bad])

    def test_duplicate_observations_and_independent_branch_order_preserve_duties(self):
        a=[row('7318.15.80',0,'Free'),row('7318.15.80.85',1)]
        b=[row('7411.10.10',0,'1.5%'),row('7411.10.10.30',1)]
        def legal(rows):
            return {p['hts10']:(p['general']['expression'],p['general']['source_code'])
                    for p in extract_rows(rows)['products']}
        self.assertEqual(legal(a+b),legal(b+a))
        self.assertEqual(legal(a+b),legal(a+[copy.deepcopy(a[-1])]+b))

    def test_actual_archive_keeps_exact_owners_and_source_hash(self):
        path=ROOT/'data/hts_archives/hts_2025_rev_8.json'
        x=extract(path,'2025_rev_8')
        p=next(p for p in x['products'] if p['hts10']=='8703230190')
        self.assertEqual(p['general']['expression'],'2.5%')
        self.assertEqual(p['general']['source_code'],'87032301')
        self.assertEqual(len(x['source']['sha256']),64)
        self.assertGreater(len(x['products']),15000)
        for p in x['products']:
            if p['general']['expression'] is not None:
                self.assertTrue(p['hts10'].startswith(p['general']['source_code']))


if __name__=='__main__':
    unittest.main()
