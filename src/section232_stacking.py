"""Source-bound post-October vehicle stacking decisions, including zero payable.

Reporting numbers are extracted from each source note. Mixed headings require
product facts; an out-of-scope use must not suppress another duty program.
"""
import json
import re
from pathlib import Path
from ieepa_fentanyl_sources import verified_source, windows
from section301_sources import clean_pages, unique_span,sha
from section232_note16_rules import val, op, both, either


def russian_aluminum_codes(schedule):
    """Native reporting roles of the original Proclamation10522 action.

    Do not expand this to a later Russia heading merely from its rate/origin.
    Later instruments can expressly retain a separate Russian-metal exception.
    """
    return sorted({r['htsno'] for r in schedule if re.fullmatch(r'9903\.\d{2}\.\d{2}',r.get('htsno','')) and
        all(s in r.get('description','') for s in ('primary aluminum','smelted in Russia','cast in Russia'))})


def russian_aluminum_stacking_source():
    root=Path(__file__).resolve().parents[1];p=root/'resources/legal_evidence/2025-09066/notice.txt'
    m=json.loads(p.with_name('source.json').read_bytes())
    if sha(p.read_bytes())!=m['sha256'] or 'encompasses Proclamation 10522' not in ' '.join(p.read_text().split()):
        raise ValueError('Unreviewed Russian-aluminum stacking inclusion')
    return dict(id='FR-2025-09066',path=str(p),**{k:m[k] for k in ('sha256','url','citation')})


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


def reporting_codes(text):
    """Expand expressly printed Chapter99 ranges, allowing sentence punctuation."""
    codes=set()
    for m in re.finditer(r'(?<![\d.])(9903\.\d{2}\.\d{2})(?:\s*[-–—]\s*(9903\.\d{2}\.\d{2}))?(?!\d|\.\d)',text):
        a,b=m.groups()
        if b:
            if a[:8]!=b[:8] or a>b:raise ValueError('Unreviewed reporting-heading range')
            codes.update(a[:8]+f'{i:02d}' for i in range(int(a[-2:]),int(b[-2:])+1))
        else:codes.add(a)
    return sorted(codes)


def note(raw,n):
    clean=clean_pages(raw)
    if re.search(r'^\s*SUBCHAPTER [IVXLCDM]+\s*$',clean,re.M):
        # Reuse the chapter inventory's outer-note boundaries. The next note
        # may start with prose rather than "(a)"; looking only for numbered
        # alphabetic notes absorbs unrelated following legal provisions.
        from chapter99_inventory import note_index
        notes,_=note_index(raw)
        matched=[r for r in notes if r['id']==f'III:{n}']
        if not matched:return {}
        if len(matched)!=1:raise ValueError('Ambiguous outer vehicle note')
        tail=re.sub(r'^\s*'+str(n)+r'\.\s*','',matched[0]['text'],count=1)
    else:
        m=re.search(r'^\s*'+str(n)+r'\.\s*(?=\n|\(a\))',clean,re.M)
        if not m:return {}
        tail=clean[m.end():];stop=re.search(r'^\s*(?:\d+\.\s+|Heading/\s+Stat\.)',tail,re.M)
        if not stop:raise ValueError('Missing end of vehicle note')
        tail=tail[:stop.start()]
    # Page margins change inside one note. A global minimum indent drops real
    # paragraphs on the other pages, while a line-wrapped "(b) of this note"
    # can look like a second subdivision. Retain structural markers and identify
    # consecutive roman lists before checking the outer alphabetic sequence.
    markers=[]
    for m in re.finditer(r'^([ \t]*)\(([a-z]+)\)([ \t]*)(?=\S|$)',tail,re.M):
        line=tail[m.end():].split('\n',1)[0]
        if len(m[3])>=2 or not line or line[0].isupper():markers.append(m)
    nested=set()
    romans=['i','ii','iii','iv','v','vi','vii','viii','ix','x','xi','xii','xiii','xiv','xv']
    for i,m in enumerate(markers):
        if m[2]!='i' or i+1>=len(markers) or markers[i+1][2]!='ii':continue
        j=0
        while i+j<len(markers) and j<len(romans) and markers[i+j][2]==romans[j]:
            nested.add(i+j);j+=1
    starts=[m for i,m in enumerate(markers) if i not in nested and len(m[2])==1]
    if not starts or [m[2] for m in starts]!=[chr(ord('a')+i) for i in range(len(starts))]:
        raise ValueError('Ambiguous or missing vehicle note subdivision')
    return {m[2]:' '.join(tail[m.end():starts[i+1].start() if i+1<len(starts) else len(tail)].split()) for i,m in enumerate(starts)}


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
