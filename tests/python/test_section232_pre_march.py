import copy
import csv
import json
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'src'))
from section232_legacy_sources import extract,matches
from section232_legacy_rules import compile_legacy
from section232_pre_march import scope_table

class PreMarch(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.x=extract(ROOT/'data/us_notes/chapter99_2025_basic.pdf',ROOT/'data/hts_archives/hts_2025_basic.json','2025_basic')
  cls.origins=dict(all=[r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open())],uk=['4120'],russia=['4621'])
 def test_complete_source_categories_and_gae(self):
  x=self.x['pre_march'];self.assertEqual(len(x['quotas']),196)
  self.assertEqual(len(x['gae']['steel']),76);self.assertEqual(len(x['gae']['aluminum']),5)
  self.assertEqual(len(x['eu_countries']),27)
 def test_country_exceptions_are_specific_to_each_metal(self):
  x=self.x['pre_march']['model_zero_country_candidates']
  for cc in ['5880','5800','3510','4623']:
   self.assertIn(cc,x['steel']);self.assertNotIn(cc,x['aluminum'])
  self.assertIn('4120',x['aluminum'])
 def test_exact_derivative_and_primary_scopes(self):
  rs=matches(self.x,['7317005503','7317005590','8708103000','8701100000','7202115000','7616995160'])
  self.assertEqual({r['hts10'] for r in rs},{'7317005503','8708103000','7616995160'})
  self.assertTrue(all(r['conditional'] for r in rs))
 def test_statistical_quota_exception_not_broadened(self):
  qs=self.x['pre_march']['quotas'];q=next(q for q in qs if q['code']=='9903.80.19')
  self.assertIn('73041910',q['includes']);self.assertIn('7304191020',q['excludes'])
  self.assertNotIn('7304191080',q['excludes'])
 def test_retired_canadian_heading_never_selected(self):
  f=compile_legacy(self.x,['7601103000'],self.origins)
  self.assertFalse(any('9903.85.21' in r['reporting_codes'] for r in f['rules']))
 def test_source_ambiguity_is_retained_not_corrected_by_digit_guess(self):
  q=next(q for q in self.x['pre_march']['quotas'] if q['code']=='9903.81.66')
  self.assertIn('92139145',q['includes']);self.assertNotIn('72139145',q['includes'])
  f=compile_legacy(self.x,['7213914500'],self.origins)
  self.assertTrue(any(r['formula'].get('unresolved_source')=='quota_category_not_established_by_archived_schedule' for r in f['rules']))
 def test_unknown_note_blocks_compilation(self):
  x=copy.deepcopy(self.x);x['pre_march']['notes'][0]['text']+=' New country exception.'
  with self.assertRaisesRegex(ValueError,'Unreviewed'):compile_legacy(x,['7208101500'],self.origins)
 def test_product_and_source_order_invariance(self):
  x=copy.deepcopy(self.x);x['pre_march']['lists']=list(reversed(x['pre_march']['lists']));x['pre_march']['quotas']=list(reversed(x['pre_march']['quotas']))
  a=compile_legacy(self.x,['7208101500','7605290000'],self.origins)
  b=compile_legacy(x,['7605290000','7208101500','7208101500'],self.origins)
  self.assertEqual(a,b)
 def test_rate_parameter_comes_from_heading_not_copied_constant(self):
  x=copy.deepcopy(self.x)
  next(h for h in x['pre_march']['headings'] if h['code']=='9903.80.01')['rate']=.27
  f=compile_legacy(x,['7208101500'],self.origins)
  self.assertTrue(any(r['formula'].get('args',[{},{}])[-1].get('value')==.27 for r in f['rules'] if r['reporting_codes']==['9903.80.01']))
 def test_unparsed_quota_description_rejected(self):
  with self.assertRaises(ValueError):scope_table('New category without a classification reference')
