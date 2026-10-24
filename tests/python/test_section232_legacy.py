import copy
import json
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))
from section232_legacy_sources import extract,matches,scoped_lists
from section232_legacy_rules import compile_legacy

class LegacyMetalSources(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.late=extract(ROOT/'data/us_notes/chapter99_2026_rev_4.pdf',ROOT/'data/hts_archives/hts_2026_rev_4.json','2026_rev_4')
  cls.early=extract(ROOT/'data/us_notes/chapter99_2025_rev_4.pdf',ROOT/'data/hts_archives/hts_2025_rev_4.json','2025_rev_4')
  cls.origins=dict(all=['5700','4120','4621','1220'],uk=['4120'],russia=['4621'])
 def test_exact_scope_and_complement(self):
  rs=matches(self.late,['7202115000','7317005503','7317005590','7308200035','7308200036'])
  self.assertFalse(any(r['hts10']=='7202115000' for r in rs))
  get=lambda h:{r['reporting_code'] for r in rs if r['hts10']==h and r['country_group']=='ordinary'}
  self.assertEqual(get('7317005503'),{'9903.81.89'})
  self.assertEqual(get('7317005590'),{'9903.81.90'})
  self.assertEqual(get('7308200035'),{'9903.81.90','9903.85.08'})
  self.assertEqual(get('7308200036'),{'9903.81.90'})
 def test_uk_note_controls_content_expression(self):
  h=next(h for h in self.late['headings'] if h['code']=='9903.81.98')
  self.assertNotIn('content',h['duty_expression'])
  self.assertEqual(h['valuation_basis'],'steel_content_value')
 def test_descriptions_are_not_broadened(self):
  for s in self.late['lists']:
   if s['id'].endswith('_C') and s['metal']=='steel':
    self.assertEqual(s['includes'],['87081030'])
    self.assertTrue(s['condition_text'])
  self.assertEqual(self.early['valid_from'],'2025-03-12T00:01:00-04:00')
 def test_old_and_replaced_regimes_not_promoted(self):
  for rev,regime in [('2025_basic','pre_march_2025'),('2026_rev_5','note16_replaced')]:
   x=extract(ROOT/f'data/us_notes/chapter99_{rev}.pdf',ROOT/f'data/hts_archives/hts_{rev}.json',rev)
   self.assertEqual(x['regime'],regime)
   if regime=='note16_replaced':
    with self.assertRaises(ValueError):compile_legacy(x,['7318158085'],self.origins)
   else:self.assertEqual(compile_legacy(x,['7318158085'],self.origins)['rules'],[])
 def test_unknown_conditions_fail(self):
  x=copy.deepcopy(self.late);x['clauses'][0]['text']+=' This duty also requires a new condition.'
  with self.assertRaisesRegex(ValueError,'Unreviewed'):compile_legacy(x,['7318158085'],self.origins)
 def test_scope_order_duplicates_do_not_change_rules(self):
  x=copy.deepcopy(self.late);x['lists']=list(reversed(x['lists']))+[x['lists'][0]]
  a=compile_legacy(self.late,['7318158085','7308200035'],self.origins)
  b=compile_legacy(x,['7308200035','7318158085','7318158085'],self.origins)
  self.assertEqual(a,b)
 def test_unknown_table_text_fails(self):
  note=next(n['text'] for n in self.late['notes'] if n['number']==19)
  note=note.replace('United States: 0402.99.68','United States: EXCEPT SOME ARTICLES 0402.99.68')
  with self.assertRaisesRegex(ValueError,'Unparsed metal table'):
   scoped_lists(note,19,'k','l','table','9903.85.08','aluminum')
 def test_rates_remain_source_parameters(self):
  x=copy.deepcopy(self.late)
  for h in x['headings']:
   if h['code']=='9903.81.90':h['rate']=.47;h['duty_expression']='The duty provided in the applicable subheading + 47%.'
  f=compile_legacy(x,['7318158085'],self.origins)
  self.assertTrue(any('0.47' in json.dumps(r['formula']) for r in f['rules']))
 def test_uncovered_product_has_no_manufactured_rules_or_claims(self):
  f=compile_legacy(self.late,['7202115000'],self.origins)
  self.assertEqual(f['rules'],[]);self.assertEqual(f['claim_definitions'],[]);self.assertEqual(f['coverage'],[])
 def test_all_ordinary_emergency_actions_follow_metal_priority(self):
  f=compile_legacy(self.late,['7318158085'],self.origins)
  edges=[e for e in f['relations'] if e['id'].endswith('_emergency')]
  self.assertTrue(edges)
  for e in edges:
   self.assertEqual(set(e['target_reporting_codes']),{'9903.01.01','9903.01.05','9903.01.10','9903.01.13','9903.01.15'})
   self.assertEqual(e['trigger_test'],'positive_duty')
  self.assertFalse(any('9903.01.16' in e['target_reporting_codes'] for e in f['relations']))
  self.assertTrue(any(s['id']=='FR-2025-14999' for s in f['sources']))
