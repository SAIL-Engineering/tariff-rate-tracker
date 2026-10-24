import copy
import csv
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'src'))
from section232_grants import load_snapshot, apply_grants
from section232_legacy_sources import extract
from section232_legacy_rules import compile_legacy

FIXTURE = ROOT/'tests/fixtures/section232_grants/snapshot.json'


class CommerceGrants(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.snapshot = load_snapshot(FIXTURE)
        x = extract(ROOT/'data/us_notes/chapter99_2025_basic.pdf',
                    ROOT/'data/hts_archives/hts_2025_basic.json', '2025_basic')
        cls.fragment = compile_legacy(x, ['7208101500','7604101000'], dict(
            all=[r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open())],
            uk=['4120'], russia=['4621']))

    def rejected(self, change, pattern):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p/'decisions.txt').write_bytes(FIXTURE.with_name('decisions.txt').read_bytes())
            x = json.loads(FIXTURE.read_bytes())
            change(x)
            (p/'snapshot.json').write_text(json.dumps(x))
            with self.assertRaisesRegex((ValueError, KeyError), pattern):
                load_snapshot(p/'snapshot.json')

    def test_missing_field_evidence_rejected(self):
        self.rejected(lambda x:x['grants'][0]['field_evidence'].pop('quantity'), 'Missing grant field')

    def test_no_number_only_authorization(self):
        self.rejected(lambda x:x['grants'][0].pop('importers'), 'Incomplete grant')

    def test_source_mutation_rejected(self):
        self.rejected(lambda x:x['sources'][0].update(sha256='0'*64), 'changed grant evidence')

    def test_fabricated_quote_rejected(self):
        self.rejected(lambda x:x['grants'][0]['field_evidence']['id'][0].update(quote='No such decision'), 'does not match')

    def test_no_post_closure_new_grant(self):
        self.rejected(lambda x:x['grants'][0].update(activated_at='2025-02-11T00:00:00-05:00'), 'after the exclusion process')

    def test_changed_interpretation_needs_new_review(self):
        self.rejected(lambda x:x['grants'][0].update(quantity=101), 'changed since review')

    def test_review_and_snapshot_are_retained(self):
        f = apply_grants(self.fragment, self.snapshot)
        pin = next(s for s in f['sources'] if s['id'].startswith('commerce-grant-snapshot-'))
        self.assertEqual(pin['sha256'], self.snapshot['snapshot_sha256'])
        self.assertTrue(any(s['source_id']==pin['id'] for s in f['source_artifacts']))

    def test_no_naive_timestamp(self):
        self.rejected(lambda x:x['grants'][0].update(entry_from='2025-01-10'), 'explicit offset')

    def test_no_hts8_broadening(self):
        self.rejected(lambda x:x['grants'][0].update(hts10=['72081015']), 'exact statistical')

    def test_duplicate_or_unreconciled_correction_rejected(self):
        self.rejected(lambda x:x['grants'].append(copy.deepcopy(x['grants'][0])), 'Duplicate grant')

    def test_no_modeled_quantity_or_unlimited_default(self):
        self.rejected(lambda x:x['grants'][0].update(quantity=0), 'Invalid approved')
        self.rejected(lambda x:x['grants'][0].update(quantity_unit='share'), 'unsupported grant quantity')

    def test_order_does_not_change_decisions(self):
        x = copy.deepcopy(self.snapshot)
        # The loader canonicalizes source grants. Apply the same canonical
        # data against reversed source rule order and compare by identity.
        f = copy.deepcopy(self.fragment)
        f['rules'].reverse()
        a = apply_grants(self.fragment, x)
        b = apply_grants(f, x)
        self.assertEqual({r['id']:r for r in a['rules']}, {r['id']:r for r in b['rules']})

    def test_quantity_is_checked_before_relief_can_suppress_duty(self):
        f = apply_grants(self.fragment, self.snapshot)
        targets = [r for r in f['rules'] if r.get('suppressed_when')]
        self.assertTrue(targets)
        self.assertTrue(all('rule_amount' in json.dumps(r['suppressed_when']) for r in targets))
        selectors = [r for r in f['rules'] if r.get('grant_id')]
        self.assertTrue(all(len(r['input_constraints'])==4 for r in selectors))
        self.assertTrue(all(r['scope']['from'] >= '2025-01-15' for r in selectors))

    def test_no_authority_coverage_is_invented(self):
        f = apply_grants(self.fragment, self.snapshot)
        self.assertEqual(f['coverage'], [])
        edge = next(e for e in f['unchanged_claims'] if e['id'].endswith('_grant_independence'))
        self.assertNotIn('base', edge['target_authorities'])
        self.assertNotIn('ieepa_reciprocal', edge['target_authorities'])
        self.assertNotIn('section_122', edge['target_authorities'])

    def test_stx_cannot_broaden_the_source_eu_country_group(self):
        x = copy.deepcopy(self.snapshot)
        g = next(g for g in x['grants'] if g['id']=='TEST_STX')
        g['countries'].append('5700')
        f = apply_grants(self.fragment, x)
        rules = [r for r in f['rules'] if r.get('grant_id')=='TEST_STX']
        self.assertTrue(rules)
        self.assertTrue(all('5700' not in r['scope']['countries'] for r in rules))
