"""Source-bound post-October vehicle stacking decisions, including zero payable.

Reporting numbers are extracted from each source note. Mixed headings require
product facts; an out-of-scope use must not suppress another duty program.
"""
import re
from ieepa_fentanyl_sources import verified_source, windows
from section301_sources import clean_pages, unique_span
from section232_note16_rules import val, op, both, either


def amendment():
    text,source=verified_source('2025-19639');flat=' '.join(text.split())
    clause=unique_span(flat,r'\(9\) The application of multiple tariffs',r'\(10\) The tariffs imposed')
    required=['remains ``subject to', 'not owed and payable due to compliance with USMCA rules of origin',
        'use of an offset adjustment', 'tariff reductions effected through the implementation of agreements on trade and security']
    if not all(s in clause for s in required):raise ValueError('Unreviewed vehicle stacking amendment')
    first=unique_span(flat,r'\(1\) Except as otherwise provided',r'\(2\) For MHDVs')
    at=windows(first)['valid_from']
    if not at:raise ValueError('Missing vehicle stacking commencement')
    return dict(effective_from=at,source=source,clause=clause)


def timber_amendment():
    text,source=verified_source('2025-19482');flat=' '.join(text.split())
    clause=unique_span(flat,r'\(6\) If any wood product',r'\(7\) Notwithstanding')
    if not all(s in clause for s in ('section 2(b) or 2(c)', 'shall be subject to the duties imposed pursuant to this proclamation, and not those imposed')):
        raise ValueError('Unreviewed timber emergency priority')
    first=unique_span(flat,r'\(5\) The rates of duty established',r'\(6\) If any wood product')
    # Same midnight-minute grammar, but this proclamation says "effective
    # with respect to goods ... on or after" before specifying the instant.
    at=windows(first)['valid_from']
    if not at:raise ValueError('Missing timber priority commencement')
    return dict(effective_from=at,source=source,clause=clause)


def reported(codes,positive=False):
    if not codes:return val(False)
    return {'reporting_predicate':dict(authority='section_232',codes=sorted(set(codes)),positive_duty=positive,exclude=False)}


def note(raw,n):
    clean=clean_pages(raw)
    m=re.search(r'^\s*'+str(n)+r'\.\s*(?=\n|\(a\))',clean,re.M)
    if not m:return {}
    # Restrict to the uniquely identified note, stopping at the next note or
    # the Chapter 99 heading table. Never find a similar subdivision elsewhere.
    tail=clean[m.end():];stop=re.search(r'^\s*(?:\d+\.\s*(?=\n|\(a\))|Heading/\s+Stat\.)',tail,re.M)
    if not stop:raise ValueError('Missing end of vehicle note')
    tail=tail[:stop.start()];starts=list(re.finditer(r'^ *\(([a-z])\)\s',tail,re.M))
    indents=[len(m[0])-len(m[0].lstrip(' ')) for m in starts if m[1]!='a']
    if indents:
        outer=min(indents)
        starts=[m for m in starts if m[1]=='a' or len(m[0])-len(m[0].lstrip(' '))<=outer+2]
    if len({m[1] for m in starts})!=len(starts):raise ValueError('Ambiguous vehicle note subdivisions')
    return {m[1]:' '.join(tail[m.end():starts[i+1].start() if i+1<len(starts) else len(tail)].split()) for i,m in enumerate(starts)}


def vehicle_predicate(schedule,raw,define,after_amendment):
    groups=[]
    # The actual note references select heading records, not a numerical range
    # or predicted reporting code. Positive pre-amendment decisions follow the
    # separately retained CBP 65054270 interpretation.
    for n in (33,38) if after_amendment else (33,):
        rows=[r for r in schedule if re.search(r'\bU\.S\. note '+str(n)+r'\b',r.get('description',''))]
        charge=[r['htsno'] for r in rows if re.search(r'[\d.]+%',r.get('general',''))]
        groups.append(reported(charge,positive=not after_amendment))
        if not after_amendment:continue
        deal=[r['htsno'] for r in rows if re.search(r'ad valorem.*equal to or greater than',r.get('description',''))]
        groups.append(reported(deal));clauses=note(raw,n)
        if not rows:continue
        if n==33:
            c=clauses.get('c','');h=clauses.get('h','')
            ccode=re.search(r'Heading (9903\.\d{2}\.\d{2}) applies to:',c)
            hcode=re.search(r'Heading (9903\.\d{2}\.\d{2}) applies to all entries',h)
            if not ccode or not hcode or 'that are not parts of passenger vehicles' not in h or 'knock-down kits or parts compilations' not in h or 'U.S. content' not in c:
                raise ValueError('Unreviewed mixed auto reporting treatment')
            groups.append(op('if',reported([ccode[1]]),define('s232_auto_approved_us_content',
                'Reporting decision represents Commerce-approved U.S. automobile content, not a non-automobile article',
                description=c),val(False)))
            groups.append(op('if',reported([hcode[1]]),define('s232_usmca_auto_parts_not_kits',
                'Actual passenger-vehicle/light-truck parts eligible for USMCA, excluding knock-down kits and compilations',
                description=h),val(False)))
        else:
            f=clauses.get('f','');k=clauses.get('k','')
            fcode=re.search(r'Heading (9903\.\d{2}\.\d{2}) applies to the U.S. content',f)
            kcode=re.search(r'Heading (9903\.\d{2}\.\d{2}) applies to all entries',k)
            if not fcode or not kcode or 'knock-down kits or parts compilations' not in k:
                raise ValueError('Unreviewed medium/heavy vehicle reporting treatment')
            groups.append(reported([fcode[1]]))
            groups.append(op('if',reported([kcode[1]]),define('s232_usmca_mhd_parts_not_kits',
                'Actual medium/heavy-duty vehicle parts eligible for USMCA, excluding knock-down kits and compilations',description=k),val(False)))
    return either(*groups)
