"""Extract revision-specific China Section 301 scopes from official HTS sources.

This is a deliberately narrow grammar, not a search for every tariff number in
Chapter 99. Each table/enumeration is bounded by its legal note subdivision.
Unknown layouts fail the build. Descriptive conditions survive as required
shipment facts; statistical references are never truncated to HTS8.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from datetime import datetime
from zoneinfo import ZoneInfo
from pathlib import Path

CODE = r"(?<![\d.])\d{4}\.\d{2}\.\d{2}(?:\.?\d{2})?(?!\d|\.\d)"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_revision_header(text: str, revision: str) -> None:
    year,kind=revision.split('_',1)
    header=text.splitlines()[0]
    revision_match = re.search(r'\bRevision\s+(\d+)\b', header)
    expected_revision = None if kind == 'basic' else kind[4:]
    actual_revision = revision_match[1] if revision_match else None
    if f'({year})' not in header or actual_revision != expected_revision:
        raise ValueError('Chapter 99 PDF header does not match the requested revision')


def clean_pages(text: str) -> str:
    lines = []
    for line in text.splitlines():
        if re.search(r"Harmonized Tariff Schedule|Annotated for Statistical|^\s*XXII\s*$|^\s*99\s*[-–]|^\s*U\.S\. Notes", line):
            continue
        lines.append(line.rstrip())
    return "\n".join(lines)


def unique_span(text: str, start: str, end: str) -> str:
    starts = list(re.finditer(start, text, re.M))
    if len(starts) != 1:
        raise ValueError(f"Expected one start {start!r}, found {len(starts)}")
    rest = text[starts[0].start():]
    finish = re.search(end, rest[1:], re.M)
    if not finish:
        raise ValueError(f"Missing end {end!r}")
    return rest[:finish.start() + 1].strip()


def codes(text: str) -> list[str]:
    return sorted({v.replace('.', '') for v in re.findall(CODE, text) if not v.startswith(('98', '99'))})


def scope_record(text: str, locator: str, *, excludes: list[str] | None = None,
                 conditional: bool = False) -> dict:
    include = codes(text)
    if not include:
        raise ValueError(f"No product scope: {locator}")
    return dict(locator=locator, includes=include, excludes=excludes or [],
                condition_text=' '.join(text.split()) if conditional else None,
                source_text=text, source_text_sha256=sha(text.encode()))


def entry_window(note: str, heading: str) -> dict:
    """Preserve the time zone actually written in law, including odd wording.

    A conflict with calendar Eastern time creates an unresolved hour, rather
    than silently substituting an offset or asserting a known duty during it.
    """
    flat = ' '.join(note.split())
    date = r'([A-Z][a-z]+ \d{1,2}, \d{4})'
    match = re.search(r'on or after 12:01 a\.m\. eastern (standard|daylight) time on '+date, flat)
    start = None
    conflict = None
    if match:
        start = datetime.strptime(match[2], '%B %d, %Y').strftime('%Y-%m-%dT00:01:00') + ('-05:00' if match[1]=='standard' else '-04:00')
        written=datetime.fromisoformat(start)
        calendar=written.replace(tzinfo=ZoneInfo('America/New_York'))
        if written.utcoffset()!=calendar.utcoffset():
            conflict=dict(written_start=start,calendar_start=calendar.isoformat(),
                          unresolved_from=min(written,calendar).isoformat(),
                          unresolved_until=max(written,calendar).isoformat())
            # The charge is definite only after both interpretations start.
            # Emit an unresolved-source interval for the conflicting hour.
            start=conflict['unresolved_until']
    elif 'on or after' in heading:
        raise ValueError('Entry date without resolved note time: '+heading)
    end = re.search(r'\bbefore '+date, heading)
    until = calendar_instant(end[1]) if end else None
    return dict(valid_from=start, valid_until=until, effective_clause=match[0] if match else None,
                start_time_conflict=conflict)


def table_and_items(span: str, locator: str) -> list[dict]:
    """Pure code rows are scope. Numbered descriptions are separate predicates.

    Delete compiler annotations only for parsing; retain the original span.
    A reference code embedded in the introductory paragraph is not a table row.
    """
    parse = re.sub(r"\[Compiler[’']s note:.*?\]", '', span, flags=re.S | re.I)
    rows = []
    table_pattern = rf"^\s*({CODE}(?:\s+{CODE})*)\s*$"
    for line in parse.splitlines():
        if re.match(table_pattern, line):
            rows.append(scope_record(line.strip(), locator + ' table'))
    starts = list(re.finditer(r"(?m)^[ \t]*\((\d+)\)[ \t]*", parse))
    for i, m in enumerate(starts):
        item = parse[m.end():starts[i+1].start() if i+1 < len(starts) else len(parse)].strip()
        # A typeset table may follow the last numbered descriptive item.
        table_start = re.search(rf'\n{table_pattern}', item, flags=re.M)
        if table_start:
            item = item[:table_start.start()].strip()
        if not item:  # Deleted item, retained in the enclosing source span.
            continue
        cs = codes(item)
        if not cs:
            raise ValueError(f"Unparsed item {locator}({m[1]}): {item[:90]}")
        bare = re.fullmatch(rf"\s*{CODE}\s*", item) is not None
        rows.append(scope_record(item, f'{locator}({m[1]})', conditional=not bare))
    if not rows:
        raise ValueError(f"Empty enumeration: {locator}")
    return rows


def set_difference_items(span: str, locator: str) -> list[dict]:
    scope = []
    items = list(re.finditer(r'(?m)^[ \t]*(\d+)\.[ \t]+', span))
    if not items:
        raise ValueError('Missing set-difference items: '+locator)
    for i, m in enumerate(items):
        item = span[m.end():items[i+1].start() if i+1<len(items) else len(span)].strip()
        before, sep, after = ' '.join(item.split()).partition(', except for ')
        if not sep or len(codes(before)) != 1 or len(codes(before)[0]) != 8 or not codes(after) or any(len(c)!=10 for c in codes(after)):
            raise ValueError('Unknown set-difference grammar: '+item)
        record = scope_record(before, f'{locator} item {m[1]}', excludes=codes(after))
        record.update(source_text=item, source_text_sha256=sha(item.encode()))
        scope.append(record)
    return scope


# A source-defined exclusion is a conditional action on named charges. Its
# product-code chronology and its grant/extension chronology are independent.
DATE_WORDS = r'([A-Z][a-z]+ \d{1,2}, \d{4})'
EVIDENCE_ROOT = Path(__file__).resolve().parents[1] / 'resources/legal_evidence'


def calendar_instant(day: str, next_day: bool = False) -> str:
    from datetime import timedelta
    value = datetime.strptime(day, '%B %d, %Y')
    if next_day:
        value += timedelta(days=1)
    return value.replace(tzinfo=ZoneInfo('America/New_York')).isoformat()


def exclusion_bindings(item: str, locator: str) -> tuple[str | None, list[dict]]:
    """Parse classification-date clauses without applying past codes forever."""
    flat = ' '.join(item.split())
    if re.match(CODE, flat):
        description, references = None, flat
    else:
        m = re.search(r'\((?:described|provided for|classified)\b', flat)
        if not m:
            raise ValueError('Unparsed exclusion description: ' + locator)
        description, references = flat[:m.start()].strip(), flat[m.start()+1:].rstrip(').')
    bindings = []
    # Some notes separate historical classifications with a comma followed by
    # a repeated "described in", rather than a semicolon. Never attach both
    # the old end date and new start date to both tariff numbers.
    for part in re.split(r';\s*|,\s*(?=(?:described|provided for|classified)\b)', references):
        cs = codes(part)
        if not cs or any(len(c) != 10 for c in cs):
            raise ValueError('Non-exact exclusion classification: ' + locator + ': ' + part)
        start = re.search(r'\beffective '+DATE_WORDS, part)
        before = re.search(r'\bprior to '+DATE_WORDS, part)
        through = re.search(r'\bthrough '+DATE_WORDS, part)
        tail = re.sub(CODE, '', part)
        tail = re.sub(r'\b(?:effective|prior to|through) '+DATE_WORDS, '', tail)
        tail = re.sub(r'\b(?:described|provided|for|in|classified|statistical|reporting|numbers?|or|and)\b', '', tail)
        if re.sub(r'[\s,().]', '', tail):
            raise ValueError('Unparsed exclusion classification qualifier: '+locator+': '+part)
        if before and through:
            raise ValueError('Conflicting exclusion classification dates: '+locator)
        if any(len(re.findall(r'\b'+word+' '+DATE_WORDS,part))>1 for word in ('effective','prior to','through')):
            raise ValueError('Multiple dates in exclusion classification clause: '+locator)
        binding=dict(codes=cs,valid_from=calendar_instant(start[1]) if start else None,
          valid_until=calendar_instant(before[1]) if before else calendar_instant(through[1],True) if through else None)
        if binding['valid_from'] and binding['valid_until'] and datetime.fromisoformat(binding['valid_from'])>=datetime.fromisoformat(binding['valid_until']):
            raise ValueError('Empty/reversed exclusion classification interval: '+locator)
        bindings.append(binding)
    return description, bindings


def exclusion_evidence(doc: str, filename: str = 'notice.txt') -> tuple[str, dict]:
    path = EVIDENCE_ROOT/doc/filename
    metadata_path=EVIDENCE_ROOT/doc/'source.json'
    metadata = json.loads(metadata_path.read_text())
    raw = path.read_bytes()
    expected = metadata['sha256'] if filename == metadata['artifact'] else next(
        (a['sha256'] for a in metadata.get('artifacts',[]) if a['path']==filename), None)
    if sha(raw) != expected:
        raise ValueError('Changed exclusion evidence: '+doc)
    return raw.decode(), dict(id='FR-'+doc+('-layout' if filename!='notice.txt' else ''),
      path=str(path),sha256=sha(raw),url=metadata['url'] if filename=='notice.txt' else metadata['url'].replace('/html/','/pdf/').replace('.htm','.pdf'),
      metadata_path=str(metadata_path),metadata_sha256=sha(metadata_path.read_bytes()),
      citation='Federal Register '+doc+'; Section 301 exclusion chronology; '+filename)


def exclusion_grant_window(text: str) -> dict:
    """Keep printed times and heading-day semantics as explicit bounds.

    Conflicting offsets and the 23:59 versus through-day boundary are not
    silently resolved. The uncertain margins cannot price a claimed exclusion.
    """
    flat = re.sub(r'(?<=\d)\s*:\s*(?=\d)', ':', ' '.join(text.split()))
    start = re.search(r'on or after (\d{1,2}:\d{2}) (a\.m\.|p\.m\.) eastern (standard|daylight) time on '+DATE_WORDS, flat, re.I)
    end = re.search(r'before (\d{1,2}:\d{2}) (a\.m\.|p\.m\.) eastern (standard|daylight) time on '+DATE_WORDS, flat, re.I)
    if not start:
        raise ValueError('Missing exclusion grant start instant')
    def instants(m):
        dt = datetime.strptime(m[4]+' '+m[1]+' '+m[2].replace('.','').upper(),'%B %d, %Y %I:%M %p')
        written = datetime.fromisoformat(dt.isoformat()+('-05:00' if m[3].lower()=='standard' else '-04:00'))
        calendar = dt.replace(tzinfo=ZoneInfo('America/New_York'))
        return written,calendar
    starts = instants(start)
    if end:
        ends = instants(end)
        end_day = calendar_instant(end[4],True)
    else:
        end_day_match = re.search(r'\bbefore '+DATE_WORDS, flat)
        if not end_day_match: raise ValueError('Missing exclusion grant end instant')
        end_day = calendar_instant(end_day_match[1])
        ends = (datetime.fromisoformat(end_day),)*2
    return dict(valid_from=max(starts).isoformat(),valid_until=min(ends).isoformat(),
      possible_from=calendar_instant(start[4]),possible_until=end_day,
      printed_from=starts[0].isoformat(),printed_until=ends[0].isoformat(),
      source_clause=flat)


def extract_exclusions(note20: str, headings: dict, note31: str = '') -> dict:
    evidence = []; modifications = []
    for doc in ('2026-17925','2026-20511'):
        text, source = exclusion_evidence(doc); evidence.append(source)
        annex = re.split(r'(?m)^Annex\s*$', text)[-1]
        annex = re.sub(r'\[\[Page \d+\]\]', '', annex)
        flat = ' '.join(annex.split())
        pattern = r'note (20\(vvv\)\([iv]+\)\(\d+\)).*?is modified by inserting ``(.*?)\'\' after ``(.*?)\'\''
        found = list(re.finditer(pattern, flat))
        if len(found) != len(re.findall('is modified by inserting',flat)) or not found:
            raise ValueError('Unparsed retroactive exclusion amendment: '+doc)
        for m in found:
            start=flat.rfind('Effective with respect',0,m.start())
            if start<0: raise ValueError('Missing amendment operative clause: '+doc)
            operative=flat[start:m.end()]
            effective = re.search(r'time on '+DATE_WORDS, operative)
            if not effective: raise ValueError('Missing amendment operative date: '+doc)
            modifications.append(dict(locator='U.S. note '+m[1],insert=m[2],after=m[3].rstrip('.'),
              effective_day=calendar_instant(effective[1]),entry_window=entry_window(operative,''),
              source_id=source['id'],source_text=m[0]))
    # Exact source subdivisions tell which charge each exclusion removes.
    sections = []
    v = unique_span(note20,r'^\s*\(vvv\)\s+\(i\)',r'^\s*\(www\)\s+The')
    roman = list(re.finditer(r'(?m)^[ \t]*(?:\(vvv\)\s*)?\(([iv]+)\)\s+The U\.S\.',v))
    if [m[1] for m in roman] != ['i','ii','iii','iv']:
        raise ValueError('Unparsed note 20(vvv) subdivisions')
    for i,m in enumerate(roman):
        sections.append(('9903.88.69','U.S. note 20(vvv)('+m[1]+')',v[m.end():roman[i+1].start() if i+1<len(roman) else len(v)]))
    start = re.search(r'(?m)^\s*\(www\)\s+The',note20)
    if not start: raise ValueError('Missing note 20(www)')
    tail = note20[start.end():]
    tail = re.split(r'(?m)^\(?21\)?(?:\.|\()',tail)[0]
    sections.append(('9903.88.70','U.S. note 20(www)',tail))
    records=[]; amendment_seen=set()
    for heading,locator,span in sections:
        items = list(re.finditer(r'(?m)^[ \t]*\((\d+)\)[ \t]+',span))
        if not items or [int(m[1]) for m in items] != list(range(1,len(items)+1)):
            raise ValueError('Missing/duplicate exclusion item: '+locator)
        intro=' '.join(span[:items[0].start()].split())
        target=re.search(r'additional duties (?:provided for in|imposed by) heading ((?:(?!additional duties).)*?) shall not apply',intro)
        if not target: raise ValueError('Missing exclusion target: '+locator)
        targets=sorted(set(re.findall(r'9903\.\d{2}\.\d{2}',target[1])))
        if not targets: raise ValueError('Empty exclusion target: '+locator)
        for i,m in enumerate(items):
            raw=' '.join(span[m.end():items[i+1].start() if i+1<len(items) else len(span)].split())
            loc=locator+'('+m[1]+')'; corrected=raw; applied=[]
            for change in modifications:
                if change['locator']!=loc: continue
                amendment_seen.add(loc)
                # A later schedule may already incorporate the exact insertion.
                expected=change['after']+' '+change['insert']
                if expected not in corrected:
                    anchor = ('effective ' if change['insert'].startswith('through ') else '') + change['after']
                    if corrected.count(anchor)!=1:
                        raise ValueError('Amendment anchor is not unique: '+loc)
                    corrected=corrected.replace(anchor,anchor+' '+change['insert'],1)
                applied.append(change)
            description,bindings=exclusion_bindings(corrected,loc)
            records.append(dict(reporting_code=heading,locator=loc,target_reporting_codes=targets,
              source_text=raw,source_text_sha256=sha(raw.encode()),amended_text=corrected,
              condition_text=description,bindings=bindings,amendments=applied))
    if amendment_seen != {m['locator'] for m in modifications}:
        raise ValueError('Retroactive amendment references absent exclusion')
    windows={'9903.88.69':[],'9903.88.70':[]}
    # The original grant annex is an image in HTML. Preserve its PDF text layer.
    base,source=exclusion_evidence('2024-11904','notice-layout.txt');evidence.append(source)
    meta=json.loads((EVIDENCE_ROOT/'2024-11904/source.json').read_text())
    artifact=next(a for a in meta['artifacts'] if a['path']=='notice.pdf')
    pdf=EVIDENCE_ROOT/'2024-11904/notice.pdf'
    if sha(pdf.read_bytes())!=artifact['sha256']: raise ValueError('Changed original exclusion annex PDF')
    evidence.append(dict(source,id='FR-2024-11904-pdf',path=str(pdf),sha256=artifact['sha256']))
    flat=' '.join(base.split())
    end=flat.find('by inserting the following new heading 9903.88.69')
    start=flat.rfind('Effective with respect',0,end)
    if end<0 or start<0: raise ValueError('Missing original .69 exclusion grant')
    windows['9903.88.69'].append(dict(**exclusion_grant_window(flat[start:end]),source_id=source['id']))
    base,source=exclusion_evidence('2024-21217');evidence.append(source)
    flat=' '.join(base.split())
    match=re.search(r'8\. Effective with respect to products of China.*?inserting the following new heading 9903\.88\.70',flat)
    if not match: raise ValueError('Missing original .70 exclusion grant')
    windows['9903.88.70'].append(dict(**exclusion_grant_window(match[0]),source_id=source['id']))
    for doc in ('2025-10203','2025-16733','2025-21671'):
        text,source=exclusion_evidence(doc);evidence.append(source)
        annexes=re.split(r'(?m)^Annex [AB]\s*$',text)[1:]
        if len(annexes)!=2: raise ValueError('Missing exclusion-extension annex: '+doc)
        for annex in annexes:
            code=re.search(r'under heading (9903\.88\.\d{2})',annex)
            if not code or code[1] not in windows: raise ValueError('Unknown exclusion extension: '+doc)
            windows[code[1]].append(dict(**exclusion_grant_window(annex),source_id=source['id']))
    # Direct heading exclusions have their own source-defined valuation and
    # contract predicates. Their tariff references may legally be HTS8; expand
    # only against the selected revision's valid products in the compiler.
    base, source = exclusion_evidence('2024-21217')
    flat = ' '.join(base.split())
    for code in ('9903.91.09', '9903.91.10'):
        heading = headings.get(code)
        if not heading or heading.get('general','').strip() != 'The duty provided in the applicable subheading':
            raise ValueError('Missing direct exclusion heading: '+code)
        description = heading['description']
        target = re.search(r'^Notwithstanding (?:subheading|heading) (9903\.\d{2}\.\d{2})',description)
        if not target: raise ValueError('Missing direct exclusion target: '+code)
        end = flat.find('inserting the following new heading '+code)
        start = flat.rfind('Effective with respect',0,end)
        if start<0 or end<0: raise ValueError('Missing direct exclusion operative clause: '+code)
        operative=flat[start:end]
        window=entry_window(operative,operative)
        if not window['valid_from'] or not window['valid_until']:
            raise ValueError('Missing direct exclusion entry window: '+code)
        day = datetime.fromisoformat(window['valid_from']).astimezone(ZoneInfo('America/New_York')).date()
        windows[code]=[dict(valid_from=window['valid_from'],valid_until=window['valid_until'],
          possible_from=calendar_instant(day.strftime('%B %d, %Y')),possible_until=window['valid_until'],
          source_id=source['id'],source_clause=operative)]
        targets=[target[1]]; source_ids=[source['id']]
        if code=='9903.91.09':
            # The implementing annex requires importer certification in addition
            # to the contract conditions printed in the reporting heading.
            certification=re.split(r'Annex D--Importer Certification',base)
            if len(certification)!=2: raise ValueError('Missing crane importer certification')
            description+=' Importer certification: '+' '.join(certification[1].split())
            for m in re.finditer(r'Heading (9903\.\d{2}\.\d{2}) shall not apply to entries under headings ([^.]*?(?:9903\.\d{2}\.\d{2}[^.]*?)+)\.', ' '.join(note31.split())):
                if code in m[2]: targets.append(m[1])
        records.append(dict(reporting_code=code,locator='Heading '+code,
          target_reporting_codes=sorted(set(targets)),source_text=heading['description'],
          source_text_sha256=sha(heading['description'].encode()),amended_text=heading['description'],
          condition_text=description,bindings=[dict(codes=codes(heading['description']),valid_from=None,valid_until=None)],
          source_ids=source_ids,amendments=[]))
    return dict(records=records,windows=windows,amendments=modifications,sources=evidence,
      limitations=['Claim effects target only the source-enumerated duties. Other investigations and Chapter 98 require separate review.',
        'Conflicting printed-time/calendar-day boundaries remain unresolved for a requested exclusion.'])


def extract(text: str, hts: list[dict], revision: str) -> dict:
    text = clean_pages(text)
    note20 = unique_span(text, r'^20\.\s*\(a\)', r'^20a?\.\s|^20\s*\(con|^21\.')
    # Note 20A (aircraft) is a separate authority action and is not China scope.
    note31 = unique_span(text, r'^31\.\s*\(a\)', r'^32\.')
    headings = {x['htsno']: x for x in hts if x.get('htsno')}
    actions = []
    bounds = [('9903.88.01', note20, 'b', 'c'), ('9903.88.02', note20, 'd', 'e'),
              ('9903.88.03', note20, 'f', 'g'), ('9903.88.04', note20, 'g', 'h'),
              ('9903.88.15', note20, 's', 't')]
    bounds += [(code, note31, letter, nxt) for code, letter, nxt in
               [('9903.91.01','b','c'), ('9903.91.02','c','d'), ('9903.91.03','d','e'),
                ('9903.91.04','e','f'), ('9903.91.05','f','g'), ('9903.91.06','g','h'),
                ('9903.91.07','h','i'), ('9903.91.08','i','j'), ('9903.91.11','j','k')]]
    for code, note, letter, nxt in bounds:
        if code not in headings:
            if code == '9903.91.11':
                continue  # Added by the December 2024 modification.
            raise ValueError(f'Missing heading {code}')
        start = (rf'^\s*\({letter}\)\s+(?:Heading {re.escape(code)}|\n)' if code == '9903.91.05'
                 else rf'^\s*\({letter}\)\s+(?:Heading|For the purposes of heading) {re.escape(code)}')
        # Some editions finish note 31 at (j), before the later (k)/(l) additions.
        if letter == 'j' and not re.search(r'^\s*\(k\)', note, re.M):
            matches = list(re.finditer(start, note, re.M))
            if len(matches) != 1:
                raise ValueError('Ambiguous note 31(j)')
            span = note[matches[0].start():].strip()
        else:
            span = unique_span(note, start, rf'^\s*\({nxt}\)\s+')
        number = 20 if code.startswith('9903.88') else 31
        locator = f'U.S. note {number}({letter})'
        if code == '9903.91.05':
            # The prospective 2027 increase is not part of the enumeration.
            span_scope = re.split(r'(?m)^\s*\(ii\)\s+', span)[0]
        else:
            span_scope = span
        if code in ('9903.91.04', '9903.91.08'):
            scope = [scope_record(span_scope, locator, conditional=code == '9903.91.04')]
        elif code == '9903.88.04':
            scope = set_difference_items(span_scope.split('Notwithstanding U.S. note 1')[0],locator)
        elif code == '9903.88.15':
            parts = re.split(r'(?m)^\s*\(ii\)\s+', span_scope)
            if len(parts) != 2:
                raise ValueError('Missing note 20(s)(ii)')
            scope = table_and_items(parts[0], locator + '(i)')
            scope += set_difference_items(parts[1],locator+'(ii)')
        else:
            scope = table_and_items(span_scope, locator)
        accounted = {c for s in scope for c in s['includes'] + s['excludes']}
        missed = set(codes(span_scope)) - accounted
        if missed:
            raise ValueError(f'Unparsed product references in {locator}: {sorted(missed)}')
        heading = headings[code]
        rate = re.fullmatch(r'The duty provided in the applicable subheading\s*(?:\+|plus)\s*(\d+(?:\.\d+)?)%', heading.get('general', '').strip())
        if not rate:
            raise ValueError('Unsupported rate expression: '+code)
        actions.append(dict(reporting_code=code, rate=float(rate[1])/100, heading=heading,
                            locator=locator, source_text=span, source_text_sha256=sha(span.encode()), scopes=scope,
                            **entry_window(span, heading['description'])))
    # The crane action is defined in the heading itself, not a note-31 table.
    # Preserve its superior text and full description instead of broadening it
    # to every crane in 8426.19.00. The exemption remains a separate claim.
    crane = headings.get('9903.92.10')
    parent = headings.get('9903.92')
    if not crane or not parent or 'China' not in parent['description']:
        raise ValueError('Missing crane heading hierarchy')
    span = parent['description'] + '\n' + crane['description']
    rate = re.fullmatch(r'The duty provided in the applicable subheading\s*\+\s*(\d+(?:\.\d+)?)%', crane['general'])
    if not rate:
        raise ValueError('Unsupported crane expression')
    # The implementing notice establishes the same entry instant as note31(b).
    origin_action = next(a for a in actions if a['reporting_code']=='9903.91.01')
    actions.append(dict(reporting_code='9903.92.10', rate=float(rate[1])/100, heading=crane,
                        locator='Heading 9903.92 and subheading 9903.92.10; note 31(a)',
                        source_text=span, source_text_sha256=sha(span.encode()),
                        scopes=[scope_record(span, 'Heading 9903.92.10', conditional=True)],
                        valid_from=origin_action['valid_from'], valid_until=None,
                        effective_clause=origin_action['effective_clause']))
    for action in actions:
        action.update(program='china_technology_transfer',country_scope='5700')
    additional_sources=[]
    # Maritime is a distinct cumulative investigation. Its one-day 2025
    # interval cannot be inferred from the later schedule's postponed date.
    for code,letter,end in [('9903.91.12','k','l'),('9903.91.14','l',None)]:
        heading=headings.get(code)
        if not heading:
            continue
        heading_date=re.search(r'on or after ([A-Z][a-z]+ \d{1,2}, \d{4})',heading['description'])
        if not heading_date: raise ValueError('Missing maritime heading entry date')
        declared_day=datetime.strptime(heading_date[1],'%B %d, %Y').strftime('%Y-%m-%d')
        if declared_day>'2026-10-22': continue
        evidence=Path(__file__).resolve().parents[1]/'resources/legal_evidence'
        original=(evidence/'2025-19568/notice.txt').read_text()
        suspension=(evidence/'2025-19873/notice.txt').read_text()
        date=entry_window(original,'')
        flat=' '.join(suspension.split())
        suspended=re.search(r'12:01 a\.m\. Eastern Standard Time on ([A-Z][a-z]+ \d{1,2}, \d{4})',flat)
        if not date['valid_from'] or not suspended or date['valid_from'][:10]!=declared_day:
            raise ValueError('Unresolved maritime start/suspension')
        until=datetime.strptime(suspended[1],'%B %d, %Y').strftime('%Y-%m-%dT00:01:00-05:00')
        start=rf'^[ \t]*\({letter}\)[ \t]*\n'
        if end:
            span=unique_span(note31,start,rf'^[ \t]*\({end}\)[ \t]*\n')
        else:
            found=list(re.finditer(start,note31,re.M))
            if len(found)!=1: raise ValueError('Ambiguous maritime note')
            span=note31[found[0].start():]
        # The scope predicate is the complete positive subdivision; opposite
        # reporting headings and their attestations are preserved in the source.
        positive=re.split(r'(?m)^[ \t]*\(ii\)[ \t]+',span)[0]
        if letter=='l':
            positive=positive.split('Heading 9903.91.14 shall not apply')[0].strip()
        rate=re.search(r'\+\s*(\d+(?:\.\d+)?)%$',heading['general'])
        if not rate: raise ValueError('Unparsed maritime rate')
        actions.append(dict(reporting_code=code,rate=float(rate[1])/100,heading=heading,
            locator=f'U.S. note 31({letter}); FR 2025-19568 Annex V.A; FR 2025-19873 suspension',
            source_text=span,source_text_sha256=sha(span.encode()),
            scopes=[scope_record(positive,f'U.S. note 31({letter})',conditional=True)],
            valid_from=date['valid_from'],valid_until=until,effective_clause=date['effective_clause'],
            start_time_conflict=date['start_time_conflict'],
            program='maritime',country_scope='5700' if letter=='k' else 'all'))
        if not additional_sources:
            for doc,day in [('2025-19568','2025-10-16'),('2025-19873','2025-11-13')]:
                file=evidence/doc/'notice.txt'
                additional_sources.append(dict(id='FR-'+doc,sha256=sha(file.read_bytes()),path=str(file),
                  url=f'https://www.govinfo.gov/content/pkg/FR-{day}/html/{doc}.htm',
                  citation=f'Federal Register {doc}: maritime action and suspension; retained operative text.'))
    inventory = []
    compiled = {a['reporting_code'] for a in actions}
    for code, heading in headings.items():
        if not re.fullmatch(r'9903\.(88|91|92)\.\d{2}',code) or not re.search(r'\+|plus',heading.get('general','')):
            continue
        description = heading['description']
        disposition = 'compiled_charge' if code in compiled else 'unresolved_source'
        if re.search(r'provision suspended',description,re.I):
            disposition = 'suspended'
        after = re.search(r'on or after ([A-Z][a-z]+ \d{1,2}, \d{4})',description)
        before = re.findall(r'before ([A-Z][a-z]+ \d{1,2}, \d{4})',description)
        date = lambda x: datetime.strptime(x,'%B %d, %Y').strftime('%Y-%m-%d')
        if disposition=='unresolved_source' and after and date(after[1])>'2026-10-22':
            disposition='future_beyond_audit_cutoff'
        if disposition=='unresolved_source' and before and max(map(date,before))<'2025-01-01':
            disposition='expired_before_audit_period'
        if disposition=='unresolved_source':
            raise ValueError('Uncompiled potentially operative China charge: '+code)
        inventory.append(dict(reporting_code=code,disposition=disposition,source_text=description,
                              from_date=date(after[1]) if after else None))
    exclusions = extract_exclusions(note20,headings,note31)
    additional_sources += exclusions['sources']
    return dict(contract_version='sail.section301-extraction/v1', revision=revision, actions=actions, exclusions=exclusions,
                charge_inventory=inventory,audit_cutoff='2026-10-22',
                additional_sources=additional_sources,
                limitations=['Notes 20/31 charge scopes, note 20(vvv)/(www) and headings 9903.91.09/.10 claims; other exclusions, Chapter 98 and other Section 301 investigations require additional rules.'])


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('pdf', 'hts', 'revision', 'output'):
        p.add_argument('--'+name, required=True)
    a = p.parse_args()
    extractor_hash=sha(Path(__file__).read_bytes())
    pdf, hts = Path(a.pdf), Path(a.hts)
    raw = subprocess.run(['pdftotext', '-layout', str(pdf), '-'], capture_output=True, check=True).stdout.decode()
    verify_revision_header(raw,a.revision)
    result = extract(raw, json.loads(hts.read_text()), a.revision)
    result['sources'] = [dict(kind='chapter99_pdf', sha256=sha(pdf.read_bytes()), path=str(pdf)),
                         dict(kind='hts_json', sha256=sha(hts.read_bytes()), path=str(hts))]
    if sha(Path(__file__).read_bytes())!=extractor_hash:
        raise ValueError('Extractor changed during source extraction')
    result['extractor_sha256'] = extractor_hash
    Path(a.output).parent.mkdir(parents=True, exist_ok=True)
    Path(a.output).write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2)+'\n')


if __name__ == '__main__':
    main()
