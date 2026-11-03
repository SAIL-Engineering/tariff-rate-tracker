"""Lossless Chapter 99 census and links to executable legal decisions.

Inventory presence, a printed rate and a linked rule are deliberately different
from complete legal coverage. Unknown provisions survive as specific questions.
No provision is classified by a predicted authority/rate or defaulted to zero.
"""
from __future__ import annotations
import argparse
import json
import re
import subprocess
from collections import defaultdict
from pathlib import Path

from section301_sources import clean_pages, sha, verify_revision_header

REPORTING = r'99\d{2}\.\d{2}(?:\.\d{2}(?:\.?\d{2})?)?'
PRODUCT = r'(?<![\d.])(?:0[1-9]|[1-8]\d|9[0-7])\d{2}(?:\.\d{2}(?:\.\d{2}(?:\.?\d{2})?)?)?(?!\d|\.\d)'
MENTION = re.compile(r'(?<![\d.])('+REPORTING+r')(?!\d|\.\d)')
ASPECTS = ('authority', 'scope', 'origin', 'reporting_role', 'legal_window', 'valuation', 'interactions')


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def unresolved_paths(node):
    if isinstance(node,dict):
        found={node['unresolved_source']} if isinstance(node.get('unresolved_source'),str) else set()
        return found | set().union(*(unresolved_paths(v) for v in node.values()))
    if isinstance(node,list):return set().union(*(unresolved_paths(v) for v in node))
    return set()


def note_index(text):
    """Preserve full outer notes once, scoped to their actual subchapter."""
    text = clean_pages(text)
    chapters = list(re.finditer(r'^\s*SUBCHAPTER ([IVXLCDM]+)\s*$', text, re.M))
    notes, sections = [], {}
    for i, chapter in enumerate(chapters):
        part = text[chapter.end():chapters[i+1].start() if i+1 < len(chapters) else len(text)]
        sections[chapter[1]] = part
        end = re.search(r'^\s*Heading/\s+Stat\.', part, re.M)
        prefix = part[:end.start()] if end else part
        starts = list(re.finditer(r'^ {0,4}(\d{1,3})\.\s+', prefix, re.M))
        for j, start in enumerate(starts):
            span = prefix[start.start():starts[j+1].start() if j+1 < len(starts) else len(prefix)].strip()
            notes.append(dict(id=f'{chapter[1]}:{start[1]}', subchapter=chapter[1], number=start[1],
                locator=f'Subchapter {chapter[1]}, U.S. note {start[1]}', text=span, sha256=sha(span.encode()),
                referenced_product_codes=sorted({m.replace('.','') for m in re.findall(PRODUCT,span)}),
                referenced_reporting_codes=sorted(set(MENTION.findall(span))),reference_membership_is_discovery_only=True))
    if len({n['id'] for n in notes}) != len(notes):
        raise ValueError('Conflicting outer Chapter 99 note identities')
    return notes, sections


def rule_index(fragments):
    rules, fragments_by_id, sources = {}, {}, {}
    spec=json.loads((Path(__file__).resolve().parents[1]/'resources/shipment_rules/fragment_contract.json').read_bytes())
    def has_node(x,key):
        return isinstance(x,dict) and (key in x or any(has_node(v,key) for v in x.values())) or isinstance(x,list) and any(has_node(v,key) for v in x)
    for fragment in fragments:
        version=fragment.get('contract_version');features=fragment.get('required_compiler_features',[])
        if version not in spec['versions'] or not isinstance(features,list) or any(f not in spec['features'] for f in features) or \
            (version==spec['feature_version'] and not features) or (version!=spec['feature_version'] and features) or \
            (fragment.get('claim_implications') and 'claim_implications' not in features) or \
            (has_node(fragment,'rule_predicate') and 'rule_value_predicates' not in features):
            raise ValueError('Unsupported inventory rule fragment')
        fid = fragment['id']
        digest = sha(encoded(fragment).encode())
        if fid in fragments_by_id and fragments_by_id[fid] != digest:
            raise ValueError('Conflicting fragment identity: '+fid)
        fragments_by_id[fid] = digest
        local_sources = {s['id']: s for s in fragment.get('sources', [])}
        for sid, source in local_sources.items():
            if sid in sources and sources[sid].get('sha256') != source.get('sha256'):
                raise ValueError('Conflicting rule source: '+sid)
            sources[sid] = source
        for rule in fragment.get('rules', []):
            rid = rule['id']
            if rid in rules and encoded(rules[rid]['definition']) != encoded(rule):
                raise ValueError('Conflicting rule definition: '+rid)
            if rule.get('verification') == 'verified' and (not rule.get('source_ids') or any(
                sid not in local_sources or local_sources[sid].get('status') != 'verified'
                or not re.fullmatch(r'[a-f0-9]{64}', local_sources[sid].get('sha256', '')) for sid in rule['source_ids'])):
                raise ValueError('Verified rule has unverified source: '+rid)
            rules[rid] = dict(fragment_id=fid, fragment_sha256=digest, definition=rule)
    links = defaultdict(list)
    for rid, item in sorted(rules.items()):
        r = item['definition']
        for code in sorted(set(r.get('reporting_codes', []))):
            if not re.fullmatch(REPORTING, code):
                raise ValueError('Invalid reporting identity: '+code)
            links[code].append(dict(rule_id=rid, fragment_id=item['fragment_id'], fragment_sha256=item['fragment_sha256'],
                action_id=r.get('action_id'), authority=r.get('authority'), kind=r.get('kind'),
                verification=r.get('verification'), scope=r.get('scope', {}), when=r.get('when'),
                formula=r.get('formula'), suppressed_when=r.get('suppressed_when'), input_constraints=r.get('input_constraints', []),
                source_ids=r.get('source_ids', [])))
    return links, sources, fragments_by_id


def extract_inventory(text, rows, revision, fragments=()):
    verify_revision_header(text, revision)
    notes, sections = note_index(text)
    mentions = set(MENTION.findall(text))
    links, rule_sources, fragment_hashes = rule_index(fragments)
    native, expressions, parents = {}, {}, []
    for row in rows:
        code = row.get('htsno', '')
        if not code.startswith('99'):
            continue
        if not re.fullmatch(REPORTING, code):
            raise ValueError('Unknown Chapter 99 code grammar: '+code)
        if code in native:
            if encoded(native[code]) != encoded(row):
                raise ValueError('Conflicting native provision: '+code)
            continue
        if code not in mentions:
            raise ValueError('Native Chapter 99 provision absent from PDF: '+code)
        native[code] = row
        indent = int(row.get('indent') or 0)
        while parents and parents[-1][0] >= indent:
            parents.pop()
        expression = row.get('general') or ''
        inherited = next(((p[2], p[1]) for p in reversed(parents) if p[2]), None)
        expressions[code] = (expression, code) if expression else inherited or ('', None)
        parents.append((indent, code, expression))
    provisions = []
    section_mentions = {section:set(MENTION.findall(part)) for section,part in sections.items()}
    note_mentions = {n['id']: set(MENTION.findall(n['text'])) for n in notes}
    notes_by_code = defaultdict(list)
    for n in notes:
        for code in note_mentions[n['id']]:notes_by_code[code].append(n)
    expired_sections = {section for section,part in sections.items() if re.search(
        r"(?:provisions of this subchapter have expired|effective period of headings? [\s\S]{0,100}has expired)",part[:3000],re.I)}
    expired_headings=set()
    for section in expired_sections:
        part=sections[section]
        table=re.search(r'^\s*Heading/\s+Stat\.',part,re.M)
        # Expiry attaches to this section's printed heading column. A cross
        # reference in an expired provision cannot expire a different action.
        body=part[table.end():] if table else part
        expired_headings.update(re.findall(r'^ {0,2}('+REPORTING+r')(?=\s)',body,re.M))
    for code in sorted(set(native) | mentions | set(links)):
        row = native.get(code)
        associated = list(notes_by_code[code])
        description = row.get('description', '') if row else ''
        for number in re.findall(r'\b(?:U\.S\.\s*)?notes?\s+(\d+)', description, re.I):
            candidates = [n for n in notes if n['number'] == number and (
                code in section_mentions.get(n['subchapter'], set()) or any(n['subchapter'] == a['subchapter'] for a in associated))]
            associated += candidates
        associated = list({n['id']: n for n in associated}.values())
        matched = links.get(code, [])
        authorities = sorted({r['authority'] for r in matched if r['authority']})
        intervals = {encoded({k:r['scope'][k] for k in ('from','until') if k in r['scope']}) for r in matched}
        legal_intervals = [json.loads(v) for v in sorted(intervals) if v != '{}']
        snapshot_status = 'not_determined'
        # This is observed snapshot status, not an inferred legal entry window.
        if row and code in expired_headings:
            snapshot_status = 'source_declares_expired'
        aspects = ['inventory_completeness'] if matched and all(r['verification']=='verified' for r in matched) else list(ASPECTS)
        gaps=[dict(rule_id=r['rule_id'],code=g) for r in matched for g in sorted(unresolved_paths(r))]
        if gaps:aspects.append('executable_gap')
        note_locators = '; '.join(n['locator'] for n in associated) or 'the original operative instrument and applicable U.S. note'
        prompts = dict(authority='Identify the operative authority and individual action',
            scope='Resolve exact product scope and description/use predicates without widening HTS10',
            origin='Resolve origin, processing/material-origin and country exceptions',
            reporting_role='Resolve whether this reports a charge, exclusion, content portion, quota or replacement',
            legal_window='Resolve original entry instants, expiry, suspension and retroactive amendments independently of the snapshot date',
            valuation='Resolve the complete duty expression, legal value/quantity basis, floors/caps and required shipment facts',
            interactions='Resolve cumulative/replacing actions, claims and other-program effects',
            inventory_completeness='Reconcile all legal alternatives and historical windows beyond the linked partial rule inventory',
            executable_gap='Resolve the explicitly uncompiled legal paths in the linked rules')
        product_codes = set(m.replace('.','') for m in re.findall(PRODUCT,description))
        expression, expression_code = expressions.get(code, ('', None))
        provisions.append(dict(revision=revision, reporting_code=code,
            presence='native_heading' if row else 'note_reference_only' if code in mentions else 'rule_source_only',
            structural_parent=len(code.replace('.', ''))<8,
            description=description, native_record=row, native_record_sha256=sha(encoded(row).encode()) if row else None,
            duty_expression=expression, expression_source_code=expression_code,
            other_expression=row.get('other') if row else None, special_expression=row.get('special') if row else None,
            note_evidence=[{k:n[k] for k in ('id','number','subchapter','locator','sha256')} for n in sorted(associated,key=lambda n:n['id'])],
            referenced_product_codes=sorted(product_codes), reference_membership_is_discovery_only=True,
            referenced_reporting_codes=sorted(set(MENTION.findall(description))),
            snapshot_status=snapshot_status, legal_intervals=legal_intervals,
            authority=authorities[0] if len(authorities)==1 else None, linked_authorities=authorities,
            rule_links=matched, status='linked_rules_partial' if matched and all(r['verification']=='verified' for r in matched) else 'unresolved_source',
            unresolved_aspects=aspects, executable_gaps=gaps,
            questions=[dict(aspect=a,question=f'{code}: {prompts[a]}; inspect {note_locators}.') for a in aspects]+[
                dict(aspect='executable_gap',rule_id=g['rule_id'],question=f"{code}: resolve {g['code']} in rule {g['rule_id']} using its source and exact entry window.") for g in gaps]))
    return dict(contract_version='sail.chapter99-action-inventory/v1', revision=revision, coverage=[],
        notes=notes, provisions=provisions, rule_sources=[rule_sources[k] for k in sorted(rule_sources)],
        fragment_hashes=fragment_hashes, sources=[],
        counts=dict(native_provisions=len(native), referenced_provisions=len(provisions), linked_provisions=sum(bool(r['rule_links']) for r in provisions)))


def build_inventory(pdf, hts, revision, fragment_paths=()):
    pdf, hts = Path(pdf), Path(hts)
    text = subprocess.check_output(['pdftotext','-layout',str(pdf),'-'], text=True)
    fragments = []
    for path in fragment_paths:
        path=Path(path)
        fragment = json.loads(path.read_bytes())
        declared={s['id']:s for s in fragment.get('sources',[])}
        backed={a['source_id'] for a in fragment.get('source_artifacts',[])}
        if any(s.get('status')=='verified' and sid not in backed for sid,s in declared.items()):
            raise ValueError('Missing verified fragment evidence: '+str(path))
        for artifact in fragment.get('source_artifacts', []):
            file=Path(artifact['path'])
            if not file.is_absolute():file=path.parent/file
            if artifact['source_id'] not in declared or declared[artifact['source_id']].get('sha256')!=artifact['sha256'] or not file.is_file() or sha(file.read_bytes()) != artifact['sha256']:
                raise ValueError('Inventory fragment source hash mismatch: '+artifact['path'])
        fragments.append(fragment)
    result = extract_inventory(text, json.loads(hts.read_bytes()), revision, fragments)
    release = revision.replace('_rev_', 'HTSRev').replace('_basic','HTSBasic')
    result['sources'] = [dict(id=f'USITC-{revision}-inventory-{kind}', path=str(path.resolve()), sha256=sha(path.read_bytes()),
        url='https://hts.usitc.gov/reststop/'+('file?release='+release+'&filename=Chapter%2099' if kind=='pdf' else 'exportList?release='+release+'&exportFormat=JSON'))
        for kind,path in [('pdf',pdf),('hts',hts)]]
    result['compiler_sha256'] = sha(Path(__file__).read_bytes())
    return result


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pdf',type=Path,required=True);p.add_argument('--hts',type=Path,required=True)
    p.add_argument('--revision',required=True);p.add_argument('--fragment',type=Path,action='append',default=[])
    p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    a.output.write_text(encoded(build_inventory(a.pdf,a.hts,a.revision,a.fragment))+'\n')
