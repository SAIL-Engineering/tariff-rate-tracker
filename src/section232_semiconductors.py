"""Source-bound note 39 decisions and original-annex amendment chronology.

The reviewed rule fragment supplies the interpreter grammar. Native notes and
heading expressions must reconcile with the original instruments, including
amendments between snapshots. Neither model rates nor inferred headings select
an action. This fragment does not attest complete Section 232 coverage.
"""
from __future__ import annotations
import argparse
import copy
from datetime import datetime, timedelta, timezone
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess
from zoneinfo import ZoneInfo

from section301_sources import sha, verify_revision_header
from section232_stacking import note
from section232_note16_rules import val, fact, op

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT/'resources/legal_evidence/section232/semiconductors'
TEMPLATE = ROOT/'resources/shipment_rules/s232_semiconductors.json'
HEADING_FIELDS = ('htsno', 'description', 'general', 'special', 'other')


def canonical(text):
    return ' '.join(text.translate(str.maketrans({'–':'-', '—':'-', '“':'"', '”':'"'})).split())


def references(text):
    result = set()
    for m in re.finditer(r'(?<![\d.])(9903\.\d{2}\.\d{2})(?:\s*[-–—]\s*(9903\.\d{2}\.\d{2}))?(?![\d.])', text):
        a, b = m.groups()
        if b:
            if a[:8] != b[:8] or a >= b:
                raise ValueError('Unreviewed semiconductor heading range')
            result.update(a[:8]+f'{n:02}' for n in range(int(a[-2:]), int(b[-2:])+1))
        else:
            result.add(a)
    return sorted(result)


def clause_a(text):
    """Separate additive/claim grammar from individually numbered exclusions."""
    text = canonical(text)
    starts = list(re.finditer(r'\((\d+)\)\s+the additional duties', text))
    if not starts or [int(m[1]) for m in starts] != list(range(1, len(starts)+1)):
        raise ValueError('Unreviewed semiconductor exclusion inventory')
    rows = []
    for i, m in enumerate(starts):
        body = text[m.end():starts[i+1].start() if i+1 < len(starts) else len(text)]
        body = re.sub(r';\s*and\s*$', '', body).strip().rstrip('; .')
        if not references(body):
            raise ValueError('Semiconductor exclusion has no reporting reference')
        rows.append(body)
    return dict(prefix=text[:starts[0].start()].strip(), rows=rows)


def at(day, standard=False):
    return datetime.strptime(day, '%B %d, %Y').replace(hour=0, minute=1,
        tzinfo=timezone(timedelta(hours=-5)) if standard else ZoneInfo('America/New_York')).isoformat()


def pdf_text(path):
    return subprocess.check_output(['pdftotext', '-layout', str(path), '-'], text=True)


@lru_cache(maxsize=1)
def load_history():
    review = json.loads((EVIDENCE/'reviewed-semantics.json').read_bytes())
    if sha(TEMPLATE.read_bytes()) != review['original_template_sha256']:
        raise ValueError('Unreviewed semiconductor interpreter template')
    template = json.loads(TEMPLATE.read_bytes())
    sources = copy.deepcopy(template['sources'])
    artifacts = copy.deepcopy(template['source_artifacts'])
    for artifact in artifacts:
        p = (TEMPLATE.parent/artifact['path']).resolve()
        if sha(p.read_bytes()) != artifact['sha256']:
            raise ValueError('Semiconductor original annex hash mismatch')
        artifact['path'] = str(p)

    def add(s):
        p = ROOT/s['path']
        if sha(p.read_bytes()) != s['sha256']:
            raise ValueError('Semiconductor amendment source hash mismatch: '+s['id'])
        sources.append({k:s[k] for k in ('id', 'sha256', 'url', 'citation')} | {'status':'verified'})
        artifacts.append(dict(source_id=s['id'], path=str(p), sha256=s['sha256']))
        return p

    meta = json.loads((ROOT/'resources/legal_evidence/2026-01052/source.json').read_bytes())
    original = add(meta | {'path':'resources/legal_evidence/2026-01052/notice.txt'})
    cbp_meta = json.loads((ROOT/'resources/legal_evidence/2026-01052/CSMS-67400472-source.json').read_bytes())
    cbp = add(cbp_meta)
    cbp_text = canonical(cbp.read_text())
    if not all(t in cbp_text for t in ('For goods that are properly classified in subheading 8473.30',
        'rather than heading 9903.01.32', 'Filers should use headings 9903.01.33, 9903.01.83, or 9903.01.87',
        'except that duties under subheading 9802.00.60 will be assessed based upon the full value')):
        raise ValueError('Unreviewed semiconductor CBP reporting/valuation instruction')
    primary = canonical(original.read_text())
    clocks = set(re.findall(r'12:01 a\.m\. eastern standard time on (\w+ \d+, \d{4})', primary))
    if len(clocks) != 1:
        raise ValueError('Missing semiconductor original commencement')
    start = at(clocks.pop(), standard=True)
    original_pdf = pdf_text(Path(artifacts[0]['path']))
    # The original technical table independently corroborates the first native
    # note's product precision and strict threshold bands, without OCR repairs.
    begin = re.search(r'\(b\)\s+For the purposes of this note,', original_pdf)
    if not begin:
        raise ValueError('Original semiconductor technical note missing')
    technical = original_pdf[begin.start():]
    primary_prefixes = re.findall(r'^\s*(\d{4}\.\d{2})\s*$', technical, re.M)
    bands = re.findall(r'greater than ([\d,]+) and less than ([\d,]+)', canonical(technical))
    baseline_rev = review['baseline_revision']
    baseline_pdf = ROOT/f'data/us_notes/chapter99_{baseline_rev}.pdf'
    baseline_json = ROOT/f'data/hts_archives/hts_{baseline_rev}.json'
    baseline = note(pdf_text(baseline_pdf), 39)
    if {k:sha(v.encode()) for k,v in baseline.items()} != review['clause_sha256']:
        raise ValueError('Unreviewed semiconductor predecessor note')
    native_prefixes = re.findall(r'(?<![\d.])\d{4}\.\d{2}(?![\d.])', baseline['b'])
    native_bands = re.findall(r'greater than ([\d,]+) and less than ([\d,]+)', baseline['b'])
    if sorted(primary_prefixes) != sorted(native_prefixes) or bands != native_bands:
        raise ValueError('Original semiconductor technical table does not reconcile')
    prefix_set = sorted({p.replace('.', '') for p in primary_prefixes})
    if any(r['scope']['hts_prefixes'] != prefix_set for r in template['rules']):
        raise ValueError('Semiconductor template scope does not reconcile')
    for p in (baseline_pdf, baseline_json):
        add(dict(id='USITC-'+baseline_rev+'-note39-'+p.suffix[1:], path=str(p.relative_to(ROOT)),
            sha256=sha(p.read_bytes()), citation='First native U.S. note 39 and reporting headings, reconciled with Proclamation 11002 Annex.',
            url='https://hts.usitc.gov/reststop/'+('file?release=2026HTSRev1&filename=Chapter%2099' if p.suffix=='.pdf' else 'exportList?release=2026HTSRev1&exportFormat=JSON')))

    inventory = json.loads((ROOT/'resources/legal_evidence/section122/interactions/review.json').read_bytes())
    required = ('FR-2026-06960', 'FR-2026-07987-txt', 'FR-2026-10571',
                'FR-2026-11314', 'FR-2026-11314-reviewed-transcription')
    paths = {s['id']:add(s) for s in inventory['sources'] if s['id'] in required}
    if set(paths) != set(required):
        raise ValueError('Incomplete semiconductor amendment evidence')
    transcription = json.loads((EVIDENCE/'transcription-source.json').read_bytes())
    p = add(transcription)
    april = canonical(p.read_text())
    if not all(t in april for t in ('deleting subdivisions (5) through (9)',
        'renumbering subdivisions (10) through (12) as (6) through (8)', 'adding new subdivision (5)')):
        raise ValueError('Unreviewed April semiconductor replacement operation')
    inserted = re.search(r'"the additional duties (.*?)"', april)
    if not inserted:
        raise ValueError('Missing April semiconductor exclusion insertion')
    april_row = inserted[1].rstrip('; .')

    def pdf_instant(id):
        days = set(re.findall(r'12:01 a\.m\. eastern daylight time on (\w+ \d+, \d{4})',
                              canonical(pdf_text(paths[id]))))
        if len(days) != 1:
            raise ValueError('Ambiguous semiconductor amendment instant: '+id)
        return at(days.pop())

    native = clause_a(baseline['a'])
    original_targets = set(c for row in native['rows'] for c in references(row))
    # The original annex's note 2(v)/(x)/(z) amendments independently establish
    # additional emergency targets, including India and Brazil. Do not discard
    # them merely because note 39(a) contains a narrower printed list.
    extra_targets = set(template['relations'][0]['target_reporting_codes']) - original_targets
    if len(native['rows']) != 12:
        raise ValueError('Incomplete original semiconductor exclusion inventory')
    states = [(start, copy.deepcopy(native), [meta['id'], 'FR-2026-01052-annex'])]
    current = copy.deepcopy(native)
    current['rows'] = current['rows'][:4]+[april_row]+current['rows'][9:]
    states.append((pdf_instant('FR-2026-06960'), copy.deepcopy(current), ['FR-2026-06960', transcription['id']]))

    april23 = canonical(paths['FR-2026-07987-txt'].read_text())
    taiwan = canonical(paths['FR-2026-10571'].read_text())
    june = canonical(paths['FR-2026-11314-reviewed-transcription'].read_text())
    def replace_from(text, pattern, instant, source_ids, row_index):
        m = re.search(pattern, text)
        if not m:
            raise ValueError('Missing original semiconductor amendment operation')
        old, new = m.groups()
        old, new = canonical(old), canonical(new)
        if current['rows'][row_index].count(old) != 1:
            raise ValueError('Semiconductor amendment predecessor does not reconcile')
        current['rows'][row_index] = current['rows'][row_index].replace(old, new)
        states.append((instant, copy.deepcopy(current), source_ids))

    clock = re.search(r'12:01 a\.m\. eastern standard time on (\w+ \d+, \d{4})', april23)
    if not clock:
        raise ValueError('Missing April 23 literal EST entry instant')
    replace_from(april23, r'9\. Subdivision \(a\) of U\.S\. note 39.*?deleting ``(.*?)\'\' and inserting ``(.*?)\'\' in lieu thereof',
                 at(clock[1], standard=True), ['FR-2026-07987-txt'], 4)
    clock = re.search(r'12:01 a\.m\. eastern time on (\w+ \d+, \d{4})', taiwan)
    if not clock:
        raise ValueError('Missing Taiwan semiconductor entry instant')
    replace_from(taiwan, r'17\. U\.S\. note 39\(a\).*?deleting ``(.*?)\'\' and inserting ``(.*?)\'\' in lieu thereof',
                 at(clock[1]), ['FR-2026-10571'], 1)
    # Restrict to section A. Section B explicitly takes effect January 1, 2028.
    june_a = june.split('B. Effective')[0]
    replace_from(june_a, r'Subdivision \(a\)\(5\) of U\.S\. note 39.*?deleting "(.*?)" and inserting "(.*?)" in lieu thereof',
                 pdf_instant('FR-2026-11314'), ['FR-2026-11314', 'FR-2026-11314-reviewed-transcription'], 4)
    until = '2026-10-23T00:00:00-04:00'
    periods = []
    active_sources = []
    for i, (date, state, source_ids) in enumerate(states):
        active_sources += source_ids
        periods.append(dict(from_=date, until=states[i+1][0] if i+1<len(states) else until,
            clause_a=state, source_ids=sorted(set(active_sources)),
            target_reporting_codes=sorted(extra_targets | {c for row in state['rows'] for c in references(row)})))
    if any(datetime.fromisoformat(p['from_']) >= datetime.fromisoformat(p['until']) for p in periods):
        raise ValueError('Semiconductor historical interval ordering error')
    return dict(start=start, until=until, periods=periods, sources=sources,
        source_artifacts=artifacts, template=template, baseline=baseline, review=review,
        hts_prefixes=prefix_set)


def extract(pdf: Path, hts: Path, revision: str):
    raw = pdf_text(pdf)
    verify_revision_header(raw, revision)
    schedule = json.loads(hts.read_bytes())
    clauses = note(raw, 39)
    headings = [{k:r.get(k, '') for k in HEADING_FIELDS} for r in schedule
                if re.fullmatch(r'9903\.79\.0[1-9]', r.get('htsno', ''))]
    provisions=sorted(set(r['htsno'].replace('.','')[:8] for r in schedule
        if re.fullmatch(r'98\d{2}\.\d{2}\.\d{2}(?:\.\d{2})?',r.get('htsno',''))))
    return dict(revision=revision, clauses=clauses, headings=headings, chapter98_provisions=provisions,
        sources=[dict(path=str(p.resolve()), sha256=sha(p.read_bytes())) for p in (pdf, hts)])


def compile_rules(x, products):
    history = copy.deepcopy(load_history())
    clauses = x['clauses']
    if clauses:
        if set(clauses) != set('abcd') or any(canonical(clauses[k]) != canonical(history['baseline'][k]) for k in 'bcd'):
            raise ValueError('Unreviewed semiconductor technical/claim predicate')
        if clause_a(clauses['a']) not in [p['clause_a'] for p in history['periods']]:
            raise ValueError('Unreviewed semiconductor stacking/valuation amendment')
        def heading_semantics(rows):
            return sorted([{k:re.sub(r'\s*\+\s*', '+', canonical(v)).rstrip('.')
                            for k,v in r.items()} for r in rows], key=lambda r:r['htsno'])
        if heading_semantics(x['headings']) != heading_semantics(history['review']['headings']):
            raise ValueError('Unreviewed semiconductor reporting expression')
    elif x['revision'] not in ('2026_basic',) and not x['revision'].startswith('2025_'):
        raise ValueError('Expected semiconductor source note is missing')
    elif x['headings']:
        raise ValueError('Semiconductor headings without their legal note')
    products = sorted(set(products))
    if any(not re.fullmatch(r'\d{10}', p) for p in products):
        raise ValueError('Invalid semiconductor HTS10 inventory')
    products = [p for p in products if any(p.startswith(prefix) for prefix in history['hts_prefixes'])]
    template = history['template']
    rules, relations = [], []
    ids = [s['id'] for s in history['sources']]
    sources, artifacts = history['sources'], history['source_artifacts']
    for i,s in enumerate(x['sources']):
        id = f'USITC-{x["revision"]}-note39-{i}'
        release = x['revision'].replace('_rev_', 'HTSRev').replace('_basic', 'HTSBasic')
        sources.append(dict(id=id, status='verified', sha256=s['sha256'], citation='Revision-specific note 39 reconciliation; original instruments determine historical entry windows.',
            url='https://hts.usitc.gov/reststop/'+(f'file?release={release}&filename=Chapter%2099' if i==0 else f'exportList?release={release}&exportFormat=JSON')))
        artifacts.append(dict(source_id=id, **s))
        ids.append(id)
    facts = copy.deepcopy(template['fact_definitions'])
    for definition in facts.values():
        definition['source_ids'] = ids
    facts['ieepa_ftz_entry'] = dict(type='boolean', label='Entry withdrawn from a U.S. foreign-trade zone',
        description='Proclamation 11002 clause 8 requires admission/status history. A current entry date alone cannot determine FTZ treatment.', source_ids=ids)
    full_value = re.search(r'except that duties under subheading (9802\.\d{2}\.\d{2}) shall be assessed based upon the full value',history['baseline']['a'])
    if not full_value or full_value[1].replace('.','') not in x['chapter98_provisions']:
        raise ValueError('Unreviewed semiconductor Chapter 98 full-value exception')
    facts['chapter98_provision'] = dict(type='string',label='Chapter 98 provision (eight digits)',
        enum=x['chapter98_provisions'], source_ids=ids)
    facts['chapter98_properly_claimed'] = dict(type='boolean',label='Entry properly claimed under the selected Chapter 98 provision',source_ids=ids)
    chapter98_eligibility = op('if', {'claim':'CHAPTER_98'},
        op('if', fact('chapter98_properly_claimed'),
            op('if', op('eq',fact('chapter98_provision'),val(full_value[1].replace('.',''))),val(True),
               {'unresolved_source':'semiconductor_chapter98_selected_provision_terms_and_valuation'}),
            {'unresolved_source':'semiconductor_chapter98_claim_eligibility_not_established'}),val(True))
    # Only the matching technical/end-use leaf requests this fact. A special
    # history may affect even an exemption; the ordinary-entry result is unsafe
    # until the matched shipment confirms that it is not an FTZ withdrawal.
    for pi, period in enumerate(history['periods'] if products and not x['revision'].startswith('2025_') else []):
        mapping = {}
        for base in template['rules']:
            r = copy.deepcopy(base)
            mapping[base['id']] = r['id'] = base['id']+f'_window{pi}'
            r['scope'] = dict(hts_exact=products, **{'from':period['from_'], 'until':period['until']})
            r['source_ids'] = ids
            if r['reporting_codes']==template['rules'][0]['reporting_codes']:
                # Chapter 98 can change liability and therefore priority. Until
                # the selected provision is priced, do not displace other duties.
                r['when'] = op('if',r['when'],chapter98_eligibility,val(False))
            r['when'] = op('if', r['when'], op('if', fact('ieepa_ftz_entry'),
                {'unresolved_source':'semiconductor_ftz_admission_status_and_privileged_rate_history'}, val(True)), val(False))
            r['formula'] = op('if', fact('ieepa_ftz_entry'),
                {'unresolved_source':'semiconductor_ftz_admission_status_and_privileged_rate_history'}, r['formula'])
            r['legal_locator'] = 'U.S. note 39; original Proclamation 11002 Annex; dated amendment chain'
            rules.append(r)
        relation = copy.deepcopy(template['relations'][0])
        relation.update(id=relation['id']+f'_window{pi}', when_rule_applies=mapping[relation['when_rule_applies']],
            target_reporting_codes=period['target_reporting_codes'], source_ids=sorted(set(period['source_ids']+['CBP-CSMS-67400472'])),
            preserve_reporting_only=True,
            period_from=period['from_'], period_until=period['until'])
        relations.append(relation)
    rids=[r['id'] for r in rules]
    return dict(contract_version=template['contract_version'], id='s232_semiconductors_'+x['revision'],
        supported_from='2026-01-01T00:00:00-05:00', supported_until=history['until'], sources=sources,
        source_artifacts=artifacts, rules=rules, relations=relations, fact_definitions=facts,
        claim_definitions=[dict(id=c,label=l,rule_ids=rids,source_ids=ids) for c,l in
            [('CHAPTER_98','Chapter 98'),('USMCA','USMCA')]] if rids else [],
        unchanged_claims=[dict(id='semiconductor_'+x['revision']+'_301_independent',claim_authority='section_301',
            candidate_required_fields=['exclusion_claim_id'],target_rule_ids=rids,source_ids=ids)] if rids else [],
        unresolved_questions=[dict(id='semiconductor_emergency_reporting_priority',
            source_ids=['CBP-CSMS-67400472'],scope_code='847330',
            question='When 9903.79.01 is legally applicable, execute reciprocal reporting 9903.01.33 in preference to Annex II 9903.01.32, and origin-specific Brazil/India headings 9903.01.83/.87 only while their own actions are operative. Do not report a terminated emergency action. Later reciprocal executable inventory is still required.'),
            dict(id='semiconductor_other_secretary_uses',source_ids=['FR-2026-01052-html'],
                 question='Acquire any subsequent Secretary-approved end-use determinations under Proclamation 11002 clause 3 before attesting complete end-use coverage.')],
        coverage=[], limitations=template['limitations']+[
            'FTZ withdrawal requires admission/status history; executable unresolved branch, not an assumed ordinary rate.',
            'Original-annex chronology through the audit cutoff does not attest coverage of any other Section 232 sector.'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pdf', type=Path, required=True)
    parser.add_argument('--hts', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = compile_rules(extract(args.pdf, args.hts, args.revision), json.loads(args.products.read_bytes()))
    result['compiler_sha256'] = sha(Path(__file__).read_bytes())
    args.output.write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
