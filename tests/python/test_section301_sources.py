import gzip
import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))
from section301_chapter98 import compile_valuations
from chapter98_rules import treatment
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
        cls.retroactive = fixture('2026_rev_11')
        if os.environ.get('S301_TEST_OUTPUT'):
            path = Path(os.environ['S301_TEST_OUTPUT'])
            path.mkdir(parents=True,exist_ok=True)
            for text,data,result in [cls.old,cls.new,cls.maritime,cls.retroactive]:
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

    def test_chapter98_targets_follow_amended_note_not_authority_name(self):
        for source in (self.old,self.new,self.maritime,self.retroactive):
            x=source[2];compiled=compile_valuations(x)
            self.assertTrue(set(['98010010','98020040','98020050','98020060','98020080'])<=set(x['chapter98_provisions']))
            for action in x['actions']:
                c=action['chapter98'];self.assertIn(action['reporting_code'],c['target_reporting_codes'])
                policy=compiled['valuations'][action['reporting_code']]['policy']
                self.assertEqual(policy['repairs'],['98020040','98020050','98020060'])
                self.assertFalse(policy['subchapter_xxiii_full_value'])
            self.assertIn('chapter98_properly_claimed',compiled['fact_definitions'])
            self.assertNotIn('chapter98_properly_claimed_and_cbp_agreed',compiled['fact_definitions'])
        self.assertIn('9903.91.14',compile_valuations(self.maritime[2])['valuations'])
        self.assertNotIn('9903.91.14',compile_valuations(self.new[2])['valuations'])

    def test_chapter98_changed_or_missing_policy_cannot_be_ordinary_duty(self):
        text,data,_=self.new
        with self.assertRaisesRegex(ValueError,'Chapter 98 clause'):
            module.extract(text.replace('properly claimed','automatically qualified'),data['headings'],'2026_rev_21')
        c=self.action('9903.88.01')['chapter98']['source_text']
        with self.assertRaisesRegex(ValueError,'valuation'):
            treatment(c.replace('less the cost or value','including the cost or value'),'section301')
        with self.assertRaisesRegex(ValueError,'claim predicate'):
            treatment(c)
        with self.assertRaisesRegex(ValueError,'valuation qualifier'):
            treatment(c.replace('performed abroad','performed in Canada'),'section301')
        with self.assertRaisesRegex(ValueError,'valuation qualifier'):
            treatment(c+' A further valuation exception applies.','section301')
        altered=text.replace('as described in heading 9802.00.80.',
            'as described in heading 9802.00.80. A further valuation exception applies.')
        with self.assertRaisesRegex(ValueError,'valuation qualifier'):
            compile_valuations(module.extract(altered,data['headings'],'2026_rev_21'))

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

    def test_exclusions_preserve_exact_target_and_description(self):
        x=self.new[2]['exclusions'];self.assertEqual(len(x['records']),180)
        record=next(r for r in x['records'] if r['locator']=='U.S. note 20(vvv)(i)(1)')
        self.assertEqual(record['target_reporting_codes'],['9903.88.01'])
        self.assertEqual(record['bindings'][0]['codes'],['8483509040'])
        self.assertIsNone(record['condition_text'])
        pump=next(r for r in x['records'] if r['locator']=='U.S. note 20(vvv)(i)(4)')
        self.assertEqual(pump['condition_text'],'Pump casings and bodies')
        self.assertEqual(pump['bindings'][-1]['valid_from'],'2026-07-01T00:00:00-04:00')
        self.assertEqual(pump['bindings'][-2]['valid_until'],'2026-07-01T00:00:00-04:00')

    def test_direct_exclusions_keep_contract_certification_and_exact_expiry(self):
        records={r['reporting_code']:r for r in self.maritime[2]['exclusions']['records']}
        crane=records['9903.91.09']; syringe=records['9903.91.10']
        self.assertEqual(crane['target_reporting_codes'],['9903.91.14','9903.92.10'])
        self.assertEqual(crane['bindings'][0]['codes'],['84261900'])
        self.assertIn('has not been modified',crane['condition_text'])
        self.assertEqual(syringe['target_reporting_codes'],['9903.91.03'])
        self.assertEqual(syringe['bindings'][0]['codes'],['9018310080'])
        windows=self.maritime[2]['exclusions']['windows']
        self.assertEqual(windows['9903.91.09'][0]['valid_until'],'2026-05-14T00:00:00-04:00')
        self.assertEqual(windows['9903.91.10'][0]['valid_until'],'2026-01-01T00:00:00-05:00')

    def test_comma_separated_historical_references_do_not_erase_lcd_exclusion(self):
        record=next(r for r in self.new[2]['exclusions']['records'] if r['locator']=='U.S. note 20(vvv)(iv)(20)')
        self.assertEqual([b['codes'] for b in record['bindings']],[['9013809000'],['8524119000']])
        self.assertEqual(record['bindings'][0]['valid_until'],record['bindings'][1]['valid_from'])
        self.assertIsNone(record['bindings'][1]['valid_until'])
        with self.assertRaisesRegex(ValueError,'Empty/reversed'):
            module.exclusion_bindings('8524.11.9000 effective January 27, 2022 prior to January 27, 2022','fixture')

    def test_retroactive_amendments_apply_to_old_sources_idempotently(self):
        for locator in ['U.S. note 20(vvv)(i)(4)','U.S. note 20(vvv)(i)(5)','U.S. note 20(vvv)(i)(6)',
                        'U.S. note 20(vvv)(i)(20)','U.S. note 20(vvv)(iv)(4)']:
            old=next(r for r in self.old[2]['exclusions']['records'] if r['locator']==locator)
            new=next(r for r in self.new[2]['exclusions']['records'] if r['locator']==locator)
            self.assertEqual(old['bindings'],new['bindings'])
            self.assertEqual(old['amended_text'],new['amended_text'])
            self.assertNotEqual(old['source_text_sha256'],new['source_text_sha256'])

    def test_code_dates_do_not_create_an_extra_product_condition(self):
        description,bindings=module.exclusion_bindings('5603.92.0090 prior to July 1, 2022; 5603.92.0070 or 5603.92.0095 effective July 1, 2022','fixture')
        self.assertIsNone(description)
        self.assertEqual(bindings[0]['valid_until'],bindings[1]['valid_from'])
        with self.assertRaisesRegex(ValueError,'qualifier'):
            module.exclusion_bindings('5603.92.0090 except unparsed restriction','fixture')

    def test_exclusion_extensions_keep_primary_time_discrepancies(self):
        x=self.new[2]['exclusions']['windows']
        self.assertEqual(len(x['9903.88.69']),4)
        initial,summer,autumn,last=x['9903.88.69']
        self.assertEqual(initial['valid_until'],'2025-05-31T23:59:00-04:00')
        self.assertEqual(summer['valid_from'],'2025-06-01T00:01:00-05:00')
        self.assertEqual(summer['possible_from'],'2025-06-01T00:00:00-04:00')
        self.assertEqual(last['possible_until'],'2026-11-10T00:00:00-05:00')


if __name__=='__main__':
    unittest.main()
