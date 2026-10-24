"""Compile reviewed Commerce decisions into the existing shipment rule AST.

The public export is discovery evidence, not an authorization. A snapshot must
carry the decision, product/party scope, activation, quantity and any correction
with field-level citations. No grant is inferred from its identifier or HTS.
"""
from copy import deepcopy
from collections import defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
from zoneinfo import ZoneInfo

from section232_note16_rules import val, fact, op, both, either

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / 'resources/legal_evidence/section232/grants'
CONTRACT = 'sail.section232-grants/v1'
FIELDS = ('id', 'metal', 'grant_type', 'hts10', 'countries', 'importers',
          'product_description', 'activated_at', 'entry_from', 'entry_until',
          'quantity', 'quantity_unit', 'actions', 'superseded_at', 'revoked_at')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def instant(value):
    if not isinstance(value, str) or not re.search(r'(Z|[+-]\d\d:\d\d)$', value):
        raise ValueError('Grant dates require an explicit offset')
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def policy_sources():
    result = []
    for source in json.loads((POLICY / 'sources.json').read_bytes()):
        path = POLICY / source['path']
        if digest(path.read_bytes()) != source['sha256']:
            raise ValueError('Changed Commerce exclusion policy evidence')
        result.append(dict(source, path=str(path)))
    return result


def activation_cutoff():
    source = next(s for s in policy_sources() if s['id']=='BIS-exclusions')
    text = ' '.join(Path(source['path']).read_text().split())
    found = re.findall(r'effective (\d{1,2}:\d{2} [AP]M) ET on ([A-Z][a-z]+ \d{1,2}, \d{4})', text)
    if len(found) != 1:
        raise ValueError('Unresolved Commerce exclusion activation cutoff')
    time, day = found[0]
    return datetime.strptime(day+' '+time,'%B %d, %Y %I:%M %p').replace(tzinfo=ZoneInfo('America/New_York'))


def load_snapshot(path):
    """Validate a reviewed interchange snapshot; never consult a moving URL."""
    path = Path(path).resolve()
    raw = path.read_bytes()
    x = json.loads(raw)
    if x.get('contract_version') != CONTRACT or not x.get('snapshot_id'):
        raise ValueError('Unsupported Commerce grant snapshot')
    instant(x['as_of'])
    cutoff = activation_cutoff()
    sources = {}
    for source in x['sources']:
        file = (path.parent / source['path']).resolve()
        if not file.is_relative_to(path.parent):
            raise ValueError('Grant evidence escapes snapshot directory')
        if source['id'] in sources or digest(file.read_bytes()) != source['sha256']:
            raise ValueError('Duplicate or changed grant evidence')
        if not source['url'].startswith('https://') or not source['citation']:
            raise ValueError('Grant source requires URL and citation')
        sources[source['id']] = dict(source, path=str(file), normalized_text=' '.join(file.read_text().split()))
    grants = {}
    for grant in x['grants']:
        if grant.get('review_status') != 'verified' or not grant.get('reviewed_by'):
            raise ValueError('Grant interpretation has not been reviewed')
        if any(k not in grant for k in FIELDS) or not re.fullmatch(r'[A-Za-z0-9_-]+', grant['id']):
            raise ValueError('Incomplete grant decision')
        if grant['id'] in grants:
            raise ValueError('Duplicate grant decision; reconcile corrections first')
        if grant['metal'] not in ('steel', 'aluminum') or grant['grant_type'] not in ('individual', 'eu_stx'):
            raise ValueError('Unsupported grant class')
        if grant['grant_type'] == 'eu_stx' and grant['metal'] != 'steel':
            raise ValueError('STX is an EU steel arrangement')
        if not grant['hts10'] or any(not re.fullmatch(r'\d{10}', h) for h in grant['hts10']):
            raise ValueError('Grant requires exact statistical products')
        if not grant['countries'] or any(not re.fullmatch(r'\d{4}', c) for c in grant['countries']):
            raise ValueError('Grant requires an explicit reviewed origin inventory')
        if not grant['importers'] or not all(isinstance(v, str) and v.strip() for v in grant['importers']):
            raise ValueError('Grant requires approved party identities')
        if any(not isinstance(grant[k], list) or len(set(grant[k])) != len(grant[k]) for k in ('hts10','countries','importers','actions')):
            raise ValueError('Grant scope inventories require unique lists')
        if not grant['product_description'].strip() or grant['quantity_unit'] not in ('kg', 'metric_ton'):
            raise ValueError('Missing product limits or unsupported grant quantity unit')
        if type(grant['quantity']) not in (int, float) or not 0 < grant['quantity'] < float('inf'):
            raise ValueError('Invalid approved grant quantity')
        if not grant['actions'] or not set(grant['actions']) <= {'ordinary_metal', 'russian_aluminum'}:
            raise ValueError('Grant action scope must be established independently')
        if grant['metal'] == 'steel' and 'russian_aluminum' in grant['actions']:
            raise ValueError('Incompatible grant authority')
        begin, end = instant(grant['entry_from']), instant(grant['entry_until'])
        active = instant(grant['activated_at'])
        if begin >= end or active >= end or active > instant(x['as_of']):
            raise ValueError('Invalid grant window')
        # The February proclamations preserved activated grants, not pending
        # applications. The exact activation is evidence; do not add five
        # calendar days or assume every decision expires after one year.
        if active >= cutoff:
            raise ValueError('Grant activated after the exclusion process ended')
        for key in ('superseded_at', 'revoked_at'):
            if grant[key] is not None and instant(grant[key]) <= begin:
                raise ValueError('Correction/revocation precedes grant window')
        for key in FIELDS:
            evidence = grant['field_evidence'].get(key, [])
            if not evidence:
                raise ValueError('Missing grant field evidence: ' + key)
            for e in evidence:
                source = sources.get(e['source_id'])
                quote = ' '.join(e['quote'].split())
                if not source or not e['locator'] or not quote or quote not in source['normalized_text']:
                    raise ValueError('Grant field citation does not match retained source: ' + key)
        reviewed = {k:grant[k] for k in FIELDS + ('field_evidence',)}
        if grant.get('review_sha256') != digest(json.dumps(reviewed, sort_keys=True, separators=(',',':')).encode()):
            raise ValueError('Grant interpretation changed since review')
        grants[grant['id']] = deepcopy(grant)
    return dict(x, grants=[grants[k] for k in sorted(grants)], sources=list(sources.values()),
                snapshot_path=str(path), snapshot_sha256=digest(raw))


def apply_grants(fragment, snapshot):
    """Add grant decisions before composition, preserving positive-duty edges.

    A zero grant action suppresses only the identified metal treatment. Other
    actions still resolve independently, including any emergency duty revived
    when metal duty is removed. Unreviewed cross-authority effects stay unpriced.
    """
    result = deepcopy(fragment)
    policy = policy_sources()
    pin = dict(id='commerce-grant-snapshot-'+snapshot['snapshot_sha256'],
               sha256=snapshot['snapshot_sha256'], path=snapshot['snapshot_path'],
               url='urn:sha256:'+snapshot['snapshot_sha256'],
               citation='Reviewed Commerce grant interchange snapshot '+snapshot['snapshot_id']+'; original decisions are cited separately.')
    for source in policy + snapshot['sources'] + [pin]:
        s = {k: source[k] for k in ('id', 'sha256', 'url', 'citation')}
        s['status'] = 'verified'
        existing = next((r for r in result['sources'] if r['id'] == s['id']), None)
        if existing and existing != s:
            raise ValueError('Conflicting grant source identity')
        if not existing:
            result['sources'].append(s)
            result['source_artifacts'].append(dict(source_id=s['id'], path=source['path'], sha256=s['sha256']))
    original = sorted(result['rules'], key=lambda r:r['id'])
    by_product = defaultdict(dict)
    for r in original:
        for h in r['scope'].get('hts_exact', []):
            by_product[(r.get('section232_metal'), h)][r['id']] = r
    selectors = []
    guards = []
    new_claims = []
    for g in snapshot['grants']:
        candidates = {}
        for h in g['hts10']:
            candidates.update(by_product[(g['metal'], h)])
        if not candidates:
            continue
        start = max(instant(g['entry_from']), instant(g['activated_at']))
        ends = [instant(g['entry_until'])] + [instant(g[k]) for k in ('superseded_at', 'revoked_at') if g[k]]
        if g['grant_type'] == 'eu_stx':
            # This is an arrangement extension, not an ordinary surviving grant.
            from section232_pre_march import transition_end
            ends.append(instant(transition_end()))
        end = min(ends)
        if end <= instant(fragment['supported_from']) or start >= instant(fragment['supported_until']):
            continue
        claim = 'section232:grant:' + g['id']
        prefix = 's232_grant_' + g['id'] + '_'
        source_ids = sorted({e['source_id'] for es in g['field_evidence'].values() for e in es} |
                            {s['id'] for s in policy})
        facts = {
            prefix+'importer': dict(type='string', label='Importer identity for Commerce grant '+g['id'], enum=g['importers']),
            prefix+'product_matches': dict(type='boolean', label='Meets every product limit of grant '+g['id'], description=g['product_description']),
            prefix+'entry_quantity': dict(type='number', minimum=0, unit=g['quantity_unit'], label='Quantity on this entry line'),
            prefix+'used_quantity': dict(type='number', minimum=0, maximum=g['quantity'], unit=g['quantity_unit'],
                label='Grant quantity consumed before this entry', description='Verified utilization across all applicable entries; not the country quota utilization or a modeled share.'),
            prefix+'utilization_verified': dict(type='boolean', label='Grant utilization reconciled for this entry and party'),
        }
        for k, v in facts.items():
            result['fact_definitions'][k] = dict(v, source_ids=source_ids)
        checks = [dict(test=op('eq', fact(prefix+'importer'), fact(prefix+'importer')), inputs=[prefix+'importer']),
                  dict(test=fact(prefix+'product_matches'), inputs=[prefix+'product_matches']),
                  dict(test=fact(prefix+'utilization_verified'), inputs=[prefix+'utilization_verified']),
                  dict(test=both(op('gt', fact(prefix+'entry_quantity'), val(0)),
                                op('lte', op('add', fact(prefix+'entry_quantity'), fact(prefix+'used_quantity')), val(g['quantity']))),
                       inputs=[prefix+'entry_quantity', prefix+'used_quantity'])]
        for c in checks:
            c['reason'] = 'Commerce grant party/product/quantity conditions must be established; split a partially covered line.'
        partitions = {}
        for r in sorted(candidates.values(), key=lambda r:r['id']):
            if g['grant_type']=='eu_stx' and r.get('section232_country_group')!='eu':
                continue
            if r.get('section232_metal') != g['metal'] or r.get('section232_treatment') not in g['actions']:
                continue
            hs = sorted(set(r['scope']['hts_exact']) & set(g['hts10']))
            cs = sorted(set(r['scope']['countries']) & set(g['countries']))
            lo = max(start, instant(r['scope']['from']))
            hi = min(end, instant(r['scope']['until']))
            if not hs or not cs or lo >= hi:
                continue
            reporting = r['grant_reporting_codes']
            # Russian action is never erased by an ordinary metal grant.
            condition = r.get('grant_material_condition', val(True))
            key = json.dumps([hs, cs, lo.isoformat(), hi.isoformat(), reporting, condition], sort_keys=True)
            if key not in partitions:
                rid = prefix+digest(key.encode())[:16]
                selector = dict(id=rid, action_id=prefix+'relief', authority='section_232', kind='duty', verification='verified',
                    scope=dict(hts_exact=hs, countries=cs, **{'from':lo.isoformat(), 'until':hi.isoformat()}),
                    when=both({'claim':claim}, condition), formula=val(0), input_constraints=checks,
                    reporting_codes=reporting, source_ids=sorted(set(source_ids+r['source_ids'])),
                    legal_locator='Commerce grant '+g['id']+'; product exclusion identifier must accompany the entry',
                    grant_id=g['id'], grant_snapshot_id=snapshot['snapshot_id'])
                partitions[key] = selector
                selectors.append(selector)
            selector = partitions[key]
            # Applicability alone deliberately does not validate quantity. Price
            # the zero action as well, so missing/invalid evidence cannot waive
            # duty through the interpreter's applicability-only path.
            eligible = op('if', {'rule_applies':selector['id']}, op('eq', {'rule_amount':selector['id']}, val(0)), val(False))
            r['suppressed_when'] = either(r['suppressed_when'], eligible) if r.get('suppressed_when') else eligible
        if partitions:
            guards.append(dict(id=prefix+'invalid_claim', action_id=prefix+'validation', authority='section_232',
                kind='duty', verification='verified', source_ids=source_ids, reporting_codes=[],
                scope={'from':fragment['supported_from'], 'until':fragment['supported_until']},
                when=both({'claim':claim}, op('not', either(*({'rule_applies':s['id']} for s in partitions.values())))),
                formula={'unresolved_source':'grant_claim_outside_verified_product_origin_material_or_entry_window:'+g['id']}))
            new_claims.append(dict(id=claim, label='Commerce grant '+g['id'], source_ids=source_ids,
                                   rule_ids=[], candidate_rule_ids=sorted(s['id'] for s in partitions.values())))
    result['rules'] += selectors + guards
    ids = sorted(r['id'] for r in result['rules'])
    for claim in result['claim_definitions']:
        # Existing metal, USMCA and GAE claims do not change grant eligibility;
        # they still operate on their original metal/emergency decisions.
        claim['rule_ids'] = sorted(set(claim['rule_ids']) | {s['id'] for s in selectors + guards})
    for claim in new_claims:
        claim['rule_ids'] = ids
    result['claim_definitions'] += new_claims
    for edge in result.get('unchanged_claims', []):
        if edge['claim_authority'] == 'section_301' and edge.get('target_rule_ids'):
            edge['target_rule_ids'] = sorted(set(edge['target_rule_ids']) | {s['id'] for s in selectors + guards})
    for s in selectors:
        result['reporting_decisions'].append(dict(rule_id=s['id'], status='compiled', reporting_codes=s['reporting_codes'],
            grant_id=s['grant_id'], grant_snapshot_id=s['grant_snapshot_id'], legal_locator=s['legal_locator']))
    if new_claims:
        result.setdefault('unchanged_claims', []).append(dict(id=result['id']+'_grant_independence',
            claim_authority='section_232', claim_ids=[c['id'] for c in new_claims],
            target_authorities=['section_301', 'ieepa_fentanyl'], source_ids=[s['id'] for s in policy]))
        result['unchanged_claims'].append(dict(id=result['id']+'_grant_ordinary_base',
            claim_authority='section_232', claim_ids=[c['id'] for c in new_claims],
            target_authorities=['base'], target_base_treatments=['column1_general','column2'],
            source_ids=[s['id'] for s in policy]))
    # Evidence is retained with the fragment; deployment still uses the existing
    # release's source hash checks and pinned trade-intelligence snapshot.
    result['grant_snapshot'] = {k:snapshot[k] for k in ('snapshot_id','as_of','snapshot_sha256')}
    result.setdefault('compiler_dependencies', {})['src/section232_grants.py'] = digest(Path(__file__).read_bytes())
    result['limitations'] += ['Grant snapshot is not an exhaustive grant registry. Grant relief before activation (refund analysis), post-April-2026 revised metal treatment, and unreviewed preference/Chapter 98/reciprocal/Section 122 effects remain outside this compiler.']
    return result


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Read-only validation of a reviewed Commerce grant snapshot; no acquisition or publication.')
    parser.add_argument('snapshot', type=Path)
    args = parser.parse_args()
    snapshot = load_snapshot(args.snapshot)
    print(json.dumps({k:snapshot[k] for k in ('contract_version','snapshot_id','snapshot_sha256','as_of')} |
                     {'grants':len(snapshot['grants']), 'sources':len(snapshot['sources'])}, indent=2))
