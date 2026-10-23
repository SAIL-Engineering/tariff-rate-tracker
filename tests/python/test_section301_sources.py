import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('s301', ROOT/'src/section301_sources.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(revision):
    root = ROOT/'tests/fixtures/section301'
    text = gzip.decompress((root/(revision+'.txt.gz')).read_bytes()).decode()
    meta = json.loads((root/(revision+'.source.json')).read_text())
    assert hashlib.sha256(text.encode()).hexdigest() == meta['text_sha256']
    data = json.loads(gzip.decompress((root/(revision+'.json.gz')).read_bytes()))
    result = module.extract(text,data['headings'],revision)
    result['sources'] = [dict(sha256=meta['pdf_sha256'],path='fixture-source-pdf'),
                         dict(sha256=meta['hts_sha256'],path='fixture-source-hts')]
    return text,data,result


class SourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old = fixture('2025_basic')
        cls.new = fixture('2026_rev_21')
        cls.maritime = fixture('2025_rev_27')
        if os.environ.get('S301_TEST_OUTPUT'):
            path = Path(os.environ['S301_TEST_OUTPUT'])
            path.mkdir(parents=True,exist_ok=True)
            for text,data,result in [cls.old,cls.new,cls.maritime]:
                (path/(result['revision']+'.json')).write_text(json.dumps(dict(extraction=result,products=data['products'])))

    def action(self,code,new=True):
        return next(a for a in (self.new if new else self.old)[2]['actions'] if a['reporting_code']==code)

    def test_exact_masks_not_entire_hts8(self):
        a=self.action('9903.91.07')
        self.assertEqual({c for s in a['scopes'] for c in s['includes']},
                         {'6307909842','6307909844','6307909850','6307909870','6307909875'})
        self.assertTrue(all(s['condition_text'] for s in a['scopes']))

    def test_future_and_expired_inventory(self):
        inventory={a['reporting_code']:a['disposition'] for a in self.new[2]['charge_inventory']}
        self.assertEqual(inventory['9903.91.12'],'future_beyond_audit_cutoff')
        self.assertEqual(inventory['9903.91.14'],'future_beyond_audit_cutoff')
        self.assertEqual(inventory['9903.88.09'],'expired_before_audit_period')
        self.assertEqual(inventory['9903.88.16'],'suspended')

    def test_dated_gloves_deletion(self):
        old={c for s in self.action('9903.91.05',False)['scopes'] for c in s['includes']}
        new={c for s in self.action('9903.91.05')['scopes'] for c in s['includes']}
        self.assertEqual(old-new,{'40151210'})
        self.assertEqual(self.action('9903.91.08')['valid_from'],'2026-01-01T00:01:00-05:00')
        self.assertTrue(all(s['condition_text'] is None for s in self.action('9903.91.05')['scopes']))

    def test_mask_effective_end_is_exclusive(self):
        a=self.action('9903.91.04')
        self.assertEqual(a['valid_from'],'2025-01-01T00:01:00-05:00')
        self.assertEqual(a['valid_until'],'2026-01-01T00:00:00-05:00')

    def test_sentence_period_is_not_part_of_code(self):
        self.assertEqual(module.codes('6307.90.9875. Next sentence; 1901.10.10; 2001.10.00'),
                         ['19011010','20011000','6307909875'])
        self.assertEqual(module.codes('9903.91.07 9802.00.80 8542.31.00123 8542.31'),[])

    def test_list3_partial_subdivision_is_not_omitted(self):
        a=self.action('9903.88.04')
        self.assertEqual(len(a['scopes']),11)
        self.assertEqual(a['rate'],.25)
        self.assertEqual(a['scopes'][-1]['includes'],['94037080'])
        self.assertEqual(a['scopes'][-1]['excludes'],['9403708003'])

    def test_set_differences_retain_every_excluded_statistical_code(self):
        a=self.action('9903.88.15')
        mask=next(s for s in a['scopes'] if s['includes']==['63079098'])
        self.assertEqual(len(mask['excludes']),5)
        battery=next(s for s in self.action('9903.88.15',False)['scopes'] if s['includes']==['85076000'])
        self.assertEqual(battery['excludes'],['8507600010'])

    def test_cranes_require_description_and_preserve_parent(self):
        a=self.action('9903.92.10')
        self.assertIn('China',a['source_text'])
        self.assertIn('ship-to-shore',a['scopes'][0]['condition_text'])
        self.assertEqual(a['scopes'][0]['includes'],['84261900'])

    def test_changed_source_grammar_fails(self):
        text,data,_=self.new
        with self.assertRaisesRegex(ValueError,'Unparsed product'):
            module.extract(text.replace('2602.00.00','2602.00.00 unnumbered qualifier'),data['headings'],'2026_rev_21')

    def test_unknown_charge_fails(self):
        text,data,_=self.new
        unknown=dict(htsno='9903.91.99',general='The duty provided in the applicable subheading + 35%',description='New China charge')
        with self.assertRaisesRegex(ValueError,'Uncompiled potentially operative'):
            module.extract(text,data['headings']+[unknown],'2026_rev_21')

    def test_archive_header_must_match_revision(self):
        module.verify_revision_header('Harmonized Tariff Schedule Revision 21 (2026)','2026_rev_21')
        module.verify_revision_header('Harmonized Tariff Schedule (2026)','2026_basic')
        with self.assertRaisesRegex(ValueError,'header does not match'):
            module.verify_revision_header('Harmonized Tariff Schedule Revision 20 (2026)','2026_rev_21')
        with self.assertRaisesRegex(ValueError,'header does not match'):
            module.verify_revision_header('Harmonized Tariff Schedule Revision 21 (2026)','2026_basic')

    def test_maritime_is_distinct_cumulative_and_cross_origin(self):
        a={r['reporting_code']:r for r in self.maritime[2]['actions']}
        self.assertEqual(a['9903.91.12']['country_scope'],'5700')
        self.assertEqual(a['9903.91.14']['country_scope'],'all')
        self.assertEqual(a['9903.91.14']['program'],'maritime')
        self.assertEqual(a['9903.91.14']['valid_until'],'2025-11-10T00:01:00-05:00')
        self.assertIn('shall also be subject',a['9903.91.14']['source_text'])
        self.assertEqual(a['9903.91.14']['rate'],1)
        self.assertEqual(a['9903.92.10']['rate'],.25)

    def test_conflicting_eastern_zone_names_do_not_assert_a_rate_in_the_gap(self):
        a=next(r for r in self.maritime[2]['actions'] if r['reporting_code']=='9903.91.14')
        self.assertEqual(a['start_time_conflict']['written_start'],'2025-11-09T00:01:00-04:00')
        self.assertEqual(a['valid_from'],'2025-11-09T00:01:00-05:00')


if __name__=='__main__':
    unittest.main()
