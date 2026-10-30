"""Bind the original optional certified automobile-part paths to shared auto logic.

Reporting rows and country floors are source data. The existing listed-part
interpreter is reused after resolving different scope, commencement and codes.
"""
import copy
import re
from section232_mhd_parts import load_history, memberships, semantic, exclusion_clause, reconcile, assert_native_presence
from section232_stacking import reporting_codes


def add_certified_history(h,x):
    m=load_history();review=m['reviewed'];original=review['note33']
    reconcile(x.get('mhd_clauses',{}),x.get('mhd_headings',[]),m)
    assert_native_presence(x['revision'],x.get('mhd_clauses',{}),m)
    for s in m['sources']:
        if not any(a['id']==s['id'] for a in h['sources']):h['sources'].append(copy.deepcopy(s))
    for a in m['source_artifacts']:
        if not any(b['source_id']==a['source_id'] for b in h['source_artifacts']):h['source_artifacts'].append(copy.deepcopy(a))
    charged=re.search(r', heading (9903\.\d{2}\.\d{2}) sets forth',original['p'])
    if not charged:raise ValueError('Missing original certified automobile-part role')
    table={r['htsno']:r for r in review['headings']}
    row=table[charged[1]]
    if any(semantic(row[k])!=semantic(h['parts']['expression']) for k in ('general','special','other')):
        raise ValueError('Certified auto part rate differs from shared original charge')
    h['certified']=dict(code=charged[1],percent=h['parts']['percent'],**{'from':m['from_']})
    for d in h['deals']:
        # All deals carry an explicit key so an unrelated sector cannot become
        # a candidate through the absence of a parsed certified reporting role.
        codes=d.get('certified',[])
        if d['country'] in ('United Kingdom','European Union','Japan'):
            codes=[r['htsno'] for r in review['headings'] if d['country'] in r['description']]
            if not codes:raise ValueError('Missing original certified country reporting rows')
        d['certified']=codes
        d['heading_expressions'].update({c:{k:table[c][k] for k in ('general','special','other')} for c in codes if c in table})
    # Each p/q/r operative condition is compared in full before its changing
    # heading inventories and independently established country extensions are
    # substituted. Unknown prose/heading references cannot disappear.
    baseline=set(reporting_codes(original['p'].split(', heading ',1)[0]))
    korean=next(d['certified'] for d in h['deals'] if d['country']=='South Korea')
    taiwan=next(d['certified'] for d in h['deals'] if d['country']=='Taiwan')
    sets=[baseline,baseline|set(korean),baseline|set(korean+taiwan)]
    def prefix(k,text):
        text=exclusion_clause(text)['prefix']
        if k=='r':
            for country in ('European Union, South Korea, Japan, and Taiwan','European Union, South Korea, and Japan'):
                text=text.replace(country,'European Union and Japan')
            text=text.replace(' or the United States-Korea Free Trade Agreement','')
        # Remove only the verified numeric list substitutions, not arbitrary
        # text surrounding them. Grammar and every non-heading condition stay.
        def sub(match):
            group=match[0];codes=set(reporting_codes(group))
            allowed=sets if k=='p' else []
            if k=='r':allowed=[s-set(next(d['certified'] for d in h['deals'] if d['country']=='United Kingdom')) for s in sets]
            if k=='q':allowed=[set(reporting_codes(original['q'].split('does not apply',1)[0]))]
            if codes not in allowed and codes!={charged[1]}:raise ValueError('Unreconciled certified automobile heading inventory')
            return '<headings>'
        text=re.sub(r'9903\.\d{2}\.\d{2}(?:(?:,?\s+(?:and|or)\s+|,\s*)9903\.\d{2}\.\d{2})*',sub,text)
        return semantic(text)
    for k in 'pqr':
        if k not in x['clauses']:continue
        now=x['clauses'][k]
        if prefix(k,now)!=prefix(k,original[k]):raise ValueError('Unreviewed certified automobile '+k+' conditions')
        parsed=exclusion_clause(now)
        targets=set(reporting_codes(' '.join(parsed['rows'])))
        # The UK role excludes the same original metals/timber but has no
        # Canada/Mexico emergency references; compare against its own original.
        prior=set(reporting_codes(' '.join(exclusion_clause(original[k])['rows'])))
        metal_original=set(m['periods'][0]['targets'])
        candidates=[prior]+[(prior-metal_original)|set(p['targets']) for p in m['periods'][1:]]
        if k=='q':
            retained=prior & metal_original
            absent=metal_original-retained
            candidates=[c-absent for c in candidates]
        if targets not in candidates:raise ValueError('Unreconciled certified automobile nonstacking chronology')
        # Code membership alone cannot approve a new qualifier or a trailing
        # legal sentence. Reconcile the complete exclusion prose as well.
        original_rows=exclusion_clause(original[k])['rows']
        row_states=[original_rows]
        removed=set(m['periods'][0]['targets'])-prior
        for period in m['periods'][1:]:
            row_states.append([row for row in period['clause']['rows'] if not set(reporting_codes(row)) & removed])
        if [semantic(row) for row in parsed['rows']] not in [[semantic(row) for row in rs] for rs in row_states]:
            raise ValueError('Unreviewed certified automobile nonstacking conditions')
    current={r['htsno']:r for r in x['headings']}
    for d in h['deals']:
        for c in d['certified']:
            if c not in current:continue
            expected=d['heading_expressions'].get(c)
            # Korea/Taiwan original four-role table is already extracted by
            # auto.load_history; retain both original unlisted-part roles.
            if expected and any(semantic(current[c][k])!=semantic(expected[k]) for k in expected):
                raise ValueError('Unreviewed certified automobile country rate')
    def members(products):return memberships(m,products,h['parts']['prefixes'])['certified']
    return dict(periods=m['periods'],members=members,
        scope_source=next(a for a in m['source_artifacts'] if a['source_id']=='FR-2025-19639-vehicle-parts-annex-reviewed'))
