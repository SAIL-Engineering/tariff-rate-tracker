"""Read IEEPA drug-emergency actions from each revision's complete U.S. note 2.

Heading numbers identify evidence, never origin or precedence. Keep exemptions,
conditional replacements, valuation provisions, and retired entry windows. This
is source extraction, not an attestation of complete shipment applicability.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import re
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo

from section301_sources import clean_pages, sha, unique_span, verify_revision_header

HEADING = r'9903\.01\.(?:0[1-9]|1[0-9]|2[0-4])'
DATE = r'([A-Z][a-z]+ \d{1,2}, \d{4})'
ROOT = Path(__file__).resolve().parents[1]


def inception_sources():
    sources = []; dates = {}
    for doc in ('2025-02293', '2025-03664', '2025-03665'):
        path = ROOT/'resources/legal_evidence'/doc/'notice.txt'
        meta = json.loads(path.with_name('source.json').read_bytes())
        if sha(path.read_bytes()) != meta['sha256']:
            raise ValueError('Emergency inception notice hash mismatch')
        text = path.read_text()
        dates_clause = unique_span(text, r'^DATES:', r'^FOR FURTHER INFORMATION')
        window = windows(dates_clause)
        if not window['valid_from']:
            raise ValueError('Unresolved emergency inception time')
        inserted = re.findall(r'by inserting the following new heading ('+HEADING+r')', ' '.join(text.split()))
        if not inserted:
            raise ValueError('Missing inception heading inventory')
        for code in inserted:
            if code in dates: raise ValueError('Conflicting inception notices')
            dates[code] = dict(valid_from=window['valid_from'],source_id=meta['id'])
        sources.append(dict(path=str(path),**meta))
    return dates,sources


def rate_replacement_source():
    path = ROOT/'resources/legal_evidence/2025-19825/notice.txt'
    source = json.loads(path.with_name('source.json').read_bytes())
    if sha(path.read_bytes()) != source['sha256']:
        raise ValueError('Emergency amendment hash mismatch')
    clause = unique_span(path.read_text(),r'^Sec\. 2\. Implementation\.',r'^Sec\. 3\.')
    flat = ' '.join(clause.split())
    heading = re.search(r'heading ('+HEADING+r") is amended by deleting ``([\d.]+)%'' each place that it appears and inserting ``([\d.]+)%'' in lieu thereof",flat)
    dates = re.search(r"by deleting ``"+DATE+r"'' and inserting ``"+DATE+r"'' in lieu thereof",flat)
    window = windows(clause)
    if not heading or not dates or not window['valid_from']:
        raise ValueError('Unparsed emergency rate/date replacement')
    old_day = datetime.strptime(dates[1],'%B %d, %Y').replace(minute=1,tzinfo=ZoneInfo('America/New_York'))
    if datetime.fromisoformat(window['valid_from']).date() != datetime.strptime(dates[2],'%B %d, %Y').date():
        raise ValueError('Emergency replacement dates disagree')
    return dict(code=heading[1],old_rate=float(heading[2])/100,new_rate=float(heading[3])/100,
        previous_from=old_day.isoformat(),effective_from=window['valid_from'],
        source=dict(path=str(path),**source),clause=clause,clause_sha256=sha(clause.encode()))


def reconcile_rate_replacement(result):
    amendment = rate_replacement_source()
    actions = [a for a in result['actions'] if a['ch99_code']==amendment['code']]
    if not actions:
        return
    if len(actions)!=1:
        raise ValueError('Ambiguous native emergency amendment target')
    native = actions[0]
    if native['rate'] not in (amendment['old_rate'],amendment['new_rate']):
        raise ValueError('Native emergency rate conflicts with replacement notice')
    # A published snapshot can already print a FUTURE replacement. Reconstruct
    # both parameter intervals from the explicit deletion/insertion, not a
    # maximum, carry-forward of a numeric rate, or an arbitrary older snapshot.
    result['actions'].remove(native)
    for rate,start,end in [(amendment['old_rate'],amendment['previous_from'],amendment['effective_from']),
                           (amendment['new_rate'],amendment['effective_from'],None)]:
        action = copy.deepcopy(native)
        action.update(rate=rate,valid_from=start,valid_until=end,
            amendment_source_id=amendment['source']['id'],amendment_source_sha256=amendment['source']['sha256'],
            amendment_effective_from=amendment['effective_from'],amendment_clause=amendment['clause'],
            # Preserve the original printed expression separately; a corrected
            # parameter must not masquerade as the unchanged native heading.
            native_duty_expression=native['duty_expression'],
            duty_expression=re.sub(r'[\d.]+%',f'{rate*100:g}%',native['duty_expression']))
        result['actions'].append(action)
    result['additional_sources'].append(amendment['source'])


def reconcile_canada_replacement(result):
    """EO 14325 sec. 2 changes covered 25% articles; sec. 3 is conditional.

    Bind by the extracted legal origin/action, not a guessed reporting number.
    The independent notice supplies the effective instant and both parameters.
    """
    candidates = [a for a in result['actions'] if a['country_names']==['Canada']
                  and a['entry_type']=='general']
    if not candidates: return
    if len(candidates)!=1: raise ValueError('Ambiguous Canadian ordinary action')
    path=ROOT/'resources/legal_evidence/2025-14999/notice.txt'
    meta=json.loads(path.with_name('source.json').read_bytes())
    if sha(path.read_bytes())!=meta['sha256']: raise ValueError('Canada amendment hash mismatch')
    implementation=unique_span(path.read_text(),r'^Sec\. 2\. Implementation\.',r'^Sec\. 3\.')
    flat=' '.join(implementation.split())
    change=re.search(r'rate of duty of ([\d.]+) percent under Executive Order 14193, as amended, shall instead be subject to an additional ad valorem rate of duty of ([\d.]+) percent',flat)
    effective=windows(implementation)['valid_from']
    if not change or not effective: raise ValueError('Unparsed Canada rate replacement')
    old,new=float(change[1])/100,float(change[2])/100
    native=candidates[0]
    if native['rate'] not in (old,new) or not native['valid_from']:
        raise ValueError('Canada heading conflicts with amendment chronology')
    inception,_=inception_sources()
    start=inception.get(native['ch99_code'],{}).get('valid_from')
    if not start: raise ValueError('Missing Canadian action inception evidence')
    result['actions'].remove(native)
    for rate,begin,end in [(old,start,effective),(new,effective,None)]:
        action=copy.deepcopy(native)
        action.update(rate=rate,valid_from=begin,valid_until=end,
            amendment_source_id=meta['id'],amendment_source_sha256=meta['sha256'],
            amendment_effective_from=effective,amendment_clause=implementation,
            native_duty_expression=native['duty_expression'],
            duty_expression=re.sub(r'[\d.]+%',f'{rate*100:g}%',native['duty_expression']))
        result['actions'].append(action)
    penalty=unique_span(path.read_text(),r'^Sec\. 3\. Transshipment\.',r'^Sec\. 4\.')
    for action in result['actions']:
        if action['country_names']==['Canada'] and action['entry_type']=='conditional_replacement':
            match=re.search(r'rate of duty of ([\d.]+) percent, in lieu of', ' '.join(penalty.split()))
            if not match or action['rate']!=float(match[1])/100:
                raise ValueError('Conditional Canada rate conflicts with notice')
            action.update(valid_from=effective,amendment_source_id=meta['id'],
                amendment_source_sha256=meta['sha256'],amendment_effective_from=effective,
                amendment_clause=penalty)
    result['additional_sources'].append(dict(path=str(path),**meta))


def windows(text):
    flat = ' '.join(text.split())
    result = dict(valid_from=None, valid_until=None, temporal_clauses=[])
    for key, prefix in [('valid_from', 'on or after'), ('valid_until', '(?:prior to|before)')]:
        pattern = prefix + r' 12:01 a\.?m\.?,? eastern (standard|daylight) time (?:on )?' + DATE
        matches = list(re.finditer(pattern, flat, re.I))
        if len(matches) > 1:
            raise ValueError('Ambiguous entry window in one operative note paragraph')
        if matches:
            m = matches[0]
            day = datetime.strptime(m[2], '%B %d, %Y').replace(hour=0, minute=1)
            calendar = day.replace(tzinfo=ZoneInfo('America/New_York'))
            written = day.isoformat() + ('-05:00' if m[1].lower() == 'standard' else '-04:00')
            if datetime.fromisoformat(written).utcoffset() != calendar.utcoffset():
                raise ValueError('Conflicting written/calendar time in IEEPA entry window')
            result[key] = written
            result['temporal_clauses'].append(m[0])
    return result


def extract_notes(text):
    # Anchor in subchapter III, not another subchapter's note 2.
    section = unique_span(clean_pages(text), r'^\s*SUBCHAPTER III\s*$',
                          r'^\s*3\.\s+For the purposes of subheadings 9903\.41')
    start = re.search(r'^\s*2\.\s*(?=\n|\(a\))', section, re.M)
    if not start:
        raise ValueError('Missing subchapter III U.S. note 2')
    note = section[start.end():]
    # The emergency subdivisions precede the distinct reciprocal note (v).
    stop = re.search(r'^\s*\(v\)\s', note, re.M)
    if stop:
        note = note[:stop.start()]
    starts = list(re.finditer(r'^\s*\(([a-u])\)\s', note, re.M))
    clauses = {}
    for i, m in enumerate(starts):
        if m[1] in clauses:
            raise ValueError('Duplicate emergency note subdivision')
        span = note[m.start():starts[i+1].start() if i+1 < len(starts) else len(note)].strip()
        clauses[m[1]] = span
    return clauses


def extract(pdf: Path, hts: Path, revision: str) -> dict:
    raw = subprocess.check_output(['pdftotext', '-layout', str(pdf), '-'], text=True)
    verify_revision_header(raw, revision)
    schedule = json.loads(hts.read_bytes())
    headings = [r for r in schedule if re.fullmatch(HEADING, r.get('htsno', ''))]
    result = dict(contract_version='sail.ieepa-emergency-extraction/v1', revision=revision,
        extractor_sha256=sha(Path(__file__).read_bytes()),
        parser_dependency_sha256=sha(Path(__file__).with_name('section301_sources.py').read_bytes()),
        sources=[dict(path=str(p.resolve()), sha256=sha(p.read_bytes())) for p in (pdf, hts)],
        clauses=[], actions=[])
    if not headings:
        return result
    inceptions, result['additional_sources'] = inception_sources()
    notes = extract_notes(raw)
    # Each operative paragraph explicitly binds a heading to its origin, even
    # when the heading description (energy, USMCA) omits the country name.
    bindings = {}
    for label, span in notes.items():
        flat = ' '.join(span.split())
        for m in re.finditer(r'(?:For the purposes of heading|Heading) (' + HEADING +
                             r'),? (?:covers only )?(?:the covered )?products of (China and Hong Kong|Mexico|Canada)\b', flat):
            if m[1] in bindings:
                raise ValueError('Ambiguous note-to-heading binding: ' + m[1])
            bindings[m[1]] = (label, m[2])
        result['clauses'].append(dict(id=label, text=span, sha256=sha(span.encode())))
    for row in headings:
        code = row['htsno']; description = row.get('description', '')
        binding = bindings.get(code)
        if binding:
            label, origin = binding
            note = notes[label]
        else:
            # Exemptions can inherit the explicit parent origin only where the
            # parent note actually references that heading. No numeric ranges.
            parents = [(label, origin) for parent, (label, origin) in bindings.items()
                       if code in notes[label]]
            origins = {origin for _, origin in parents}
            explicit = re.search(r'(?:product|products) of (China and Hong Kong|Mexico|Canada)\b', description)
            if explicit:
                origin = explicit[1]
                if origins and origin not in origins:
                    raise ValueError('Heading/note origin disagreement: ' + code)
            elif len(origins) == 1:
                origin = origins.pop()
            else:
                raise ValueError('Unresolved origin for emergency heading: ' + code)
            label = None
            note = '\n\n'.join(notes[k] for k in sorted({p[0] for p in parents}))
        expression = row.get('general', '').strip()
        surcharge = re.fullmatch(r'The duty provided in the applicable subheading\s*\+\s*([\d.]+)%', expression)
        if surcharge:
            rate = float(surcharge[1])/100
            if not binding:
                raise ValueError('Positive action without operative note: ' + code)
            conditional = 'transshipped to evade' in description
            kind = 'conditional_replacement' if conditional else (
                'general' if re.match('Except for products described', description) else 'carveout')
            opening = ' '.join(note.split()).split('Notwithstanding U.S. note')[0]
            # A note may bind multiple headings with distinct ordinary rates.
            local = re.search(r'For the purposes of heading ' + re.escape(code) + r'.*?additional ([\d.]+)\s*% ad valorem', opening)
            if not local or float(local[1])/100 != rate:
                raise ValueError('Heading/note rate disagreement: ' + code)
            temporal = windows(opening)
        elif expression in ('The duty provided in the applicable subheading', 'No change'):
            rate = 0
            kind = 'exemption'
            temporal = dict(valid_from=None, valid_until=None, temporal_clauses=[])
        else:
            raise ValueError('Unparsed emergency duty expression: ' + code)
        inception = inceptions.get(code)
        if inception and temporal['valid_from'] is None:
            temporal['valid_from'] = inception['valid_from']
            temporal['inception_source_id'] = inception['source_id']
        result['actions'].append(dict(ch99_code=code, country_names=origin.split(' and '),
            rate=rate, entry_type=kind, source_description=description, duty_expression=expression,
            note_locator=f'U.S. note 2({label})' if label else 'U.S. note 2; heading and explicit parent references',
            source_note=note, source_note_sha256=sha(note.encode()),
            source_heading_sha256=sha(json.dumps(row, sort_keys=True).encode()), **temporal))
    if len({a['ch99_code'] for a in result['actions']}) != len(headings):
        raise ValueError('Duplicate emergency heading')
    reconcile_rate_replacement(result)
    reconcile_canada_replacement(result)
    return result


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    for key in ('pdf', 'hts', 'output'):
        p.add_argument('--'+key, type=Path, required=True)
    p.add_argument('--revision', required=True)
    args = p.parse_args()
    args.output.write_text(json.dumps(extract(args.pdf, args.hts, args.revision), indent=2)+'\n')
