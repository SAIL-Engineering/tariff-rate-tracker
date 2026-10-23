"""Extract verified retroactive ordinary country-rate amendments.

Only bounded notice annexes are read. Product exclusions and Chapter 98 effects
remain separate; the emitted actions preserve those references, not an assertion
that every article of the country owes the floor. Unknown table grammar fails.
"""
import json
from pathlib import Path
import re
import sys
from datetime import datetime, timedelta
from section301_sources import calendar_instant, sha

ROOT=Path(__file__).resolve().parents[1]
# These are legal document locators, not product/origin correction examples.
LOCATORS=[('2025-17908',r'^Annex I\na\. Effective',r'^b\. Effective'),
          ('2025-21940',r'^B\. Effective',None),
          ('2025-23316',r'^Annex II\nEffective',None)]


def extract_country_amendment(text, start, end=None):
    starts=list(re.finditer(start,text,re.M))
    if len(starts)!=1:raise ValueError('Missing/ambiguous amendment annex')
    span=text[starts[0].start():]
    if end:
        stop=re.search(end,span,re.M)
        if not stop:raise ValueError('Unbounded amendment annex')
        span=span[:stop.start()]
    flat=' '.join(span.split())
    date=re.search(r'on or after 12:01 a\.m\. eastern time on ([A-Za-z]+ \d{1,2}, \d{4})',flat)
    if not date:raise ValueError('Unresolved amendment effective time')
    retired=re.search(r'Headings? (9903\.\d{2}\.\d{2}(?: and 9903\.\d{2}\.\d{2})*) (?:is|are) (?:hereby )?terminated',flat)
    if not retired:raise ValueError('Missing explicit replaced headings')
    terminated=re.findall(r'9903\.\d{2}\.\d{2}',retired[1])
    boundaries=list(re.finditer(r'^(9903\.\d{2}\.\d{2})\.{2,}',span,re.M))
    actions=[]
    for i,m in enumerate(boundaries):
        # Annexes can also modify wood/vehicle Section 232 headings. They
        # are independent authorities, not ordinary reciprocal replacements.
        if not m[1].startswith('9903.02.'):continue
        table=span[m.start():boundaries[i+1].start() if i+1<len(boundaries) else len(span)]
        first=table.splitlines()[0]
        rate=re.search(r'\s(\d+(?:\.\d+)?)%\.{2,}',first)
        if not rate:continue  # companion no-additional and product-exclusion headings
        country=re.search(r'articles the product of ([A-Z][A-Za-z ]+),',' '.join(table.split()))
        if not country:raise ValueError('Unresolved floor origin: '+m[1])
        if not re.search(r'(?:column 1(?:-General|--General)?(?: or column 1(?:-Special|--Special)?)?|duty) less than '+rate[1]+' percent', ' '.join(table.split())):
            raise ValueError('Unresolved floor predicate: '+m[1])
        actions.append(dict(ch99_code=m[1],country_name=country[1],rate=float(rate[1])/100,
            rate_type='floor',source_description=' '.join(table.split()),duty_expression=rate[1]+'%',
            source_heading_sha256=sha(table.encode())))
    if not actions or len(actions)!=len(terminated):raise ValueError('Incomplete country amendment inventory')
    effective=(datetime.fromisoformat(calendar_instant(date[1]))+timedelta(minutes=1)).isoformat()
    return dict(effective_from=effective,
        effective_clause=date[0],terminated_codes=terminated,actions=actions,source_scope_sha256=sha(span.encode()))


def load_amendments():
    rows=[]
    for doc,start,end in LOCATORS:
        root=ROOT/'resources/legal_evidence'/doc
        source=json.loads((root/'source.json').read_bytes());raw=(root/'notice.txt').read_bytes()
        if sha(raw)!=source['sha256']:raise ValueError('Amendment evidence hash mismatch: '+doc)
        row=extract_country_amendment(raw.decode(),start,end)
        row.update(source=source,source_path=str(root/'notice.txt'))
        rows.append(row)
    return rows


if __name__=='__main__':
    Path(sys.argv[1]).write_text(json.dumps(load_amendments(),indent=2)+'\n')
