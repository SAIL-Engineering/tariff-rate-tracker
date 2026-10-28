"""Complete note52 product annexes; conditions never disappear into HTS scopes.

Original USTR tables are executable extraction data. Reviewed prose supplies
the predicate kind. Native snapshots corroborate them but cannot silently
delete original scope. Every table token and description must be consumed.
"""
from pathlib import Path
import json
import re
from section301_sources import sha
from section232_stacking import reporting_codes

ROOT=Path(__file__).resolve().parents[1]
H=r'9903\.\d{2}\.\d{2}'
P=r'(?<![\d.])\d{4}\.\d{2}\.\d{2}(?:\.?\d{2})?(?![\d.])'
LEAD=r'As provided in heading ('+H+r'), the (?:additional )?dut(?:y|ies) imposed by headings? ('+H+r'(?:-\s*'+H+r')?) shall not apply to '


def flat(text):
    text=' '.join(text.translate(str.maketrans({'–':'-','—':'-','“':'"','”':'"','’':"'"})).split())
    return re.sub(r'(?<=\w)-\s+(?=\w)','-',text).rstrip(' ."')


def sections(note):
    """Return whole prose/table blocks, before semantic interpretation."""
    result=[]
    for key in ('c','d','e'):
        text=flat(note[key]);m=re.match(LEAD,text)
        if not m:raise ValueError('Unreviewed product-annex lead: '+key)
        prefix,sep,body=text.partition(':')
        if not sep:raise ValueError('Missing product-annex delimiter: '+key)
        result.append(dict(locator='note52('+key+')',reporting_code=m[1],target_reporting_codes=reporting_codes(m[2]),
            prefix=prefix,body=body,particular=key=='c'))
    text=flat(note['j']);starts=list(re.finditer(LEAD,text))
    if not starts:raise ValueError('Missing partner product annexes')
    if text[:starts[0].start()].strip()!='(1)':raise ValueError('Unparsed partner annex introduction')
    for i,m in enumerate(starts):
        tail=text[m.start():starts[i+1].start() if i+1<len(starts) else len(text)]
        # These are the next block's structural labels, never product prose.
        tail=re.sub(r'(?:\s*\((?:\d+|[ivx]+)\))+\s*$','',tail).strip()
        prefix,sep,body=tail.partition(':')
        if not sep:raise ValueError('Missing partner product table delimiter')
        result.append(dict(locator='note52(j):'+m[1],reporting_code=m[1],target_reporting_codes=reporting_codes(m[2]),
            prefix=prefix,body=body,particular='following particular articles' in prefix))
    if len({s['reporting_code'] for s in result})!=len(result):raise ValueError('Duplicate product-annex reporting provision')
    return result


def table(text):
    printed=re.findall(P,text)
    if not printed or re.sub(P,'',text).strip():raise ValueError('Unparsed product-annex table content')
    return sorted({c.replace('.','') for c in printed})


def descriptions(text):
    markers=list(re.finditer(r'\(([A-Z]|\d+)\)\s*',text))
    if not markers or text[:markers[0].start()].strip():raise ValueError('Unparsed particular-product introduction')
    expected=[str(i+1) for i in range(len(markers))] if markers[0][1].isdigit() else [chr(65+i) for i in range(len(markers))]
    if [m[1] for m in markers]!=expected:raise ValueError('Unaccounted particular-product items')
    result=[]
    for i,m in enumerate(markers):
        item=text[m.end():markers[i+1].start() if i+1<len(markers) else len(text)].strip()
        # The separators are legal enumeration punctuation, not scope words.
        item=re.sub(r';?\s+and\s*$','',item).rstrip(';. ')
        parsed=re.fullmatch(r'(.+?)\s*\(classifiable in subheading ('+P+r')\)',item)
        if not parsed:raise ValueError('Unparsed particular-product description')
        result.append(dict(item=m[1],includes=[parsed[2].replace('.','')],condition_text=parsed[1],
            condition='article_description',source_scope_sha256=sha(flat(item).encode())))
    return result


def product_exemptions(note):
    review=json.loads((ROOT/'resources/legal_evidence/section301/forced-labor/reviewed-annexes.json').read_bytes())
    if review['contract_version']!='sail.section301-forced-labor-annex-review/v1':raise ValueError('Unsupported annex semantic review')
    if review['particular_clause_sha256']!=sha(flat(note['c']).encode()):raise ValueError('Unreviewed particular-product condition')
    result=[]
    for section in sections(note):
        reviewed=review['provisions'].get(section['reporting_code'])
        if not reviewed or reviewed['prefix_sha256']!=sha(section['prefix'].encode()):raise ValueError('Unreviewed product-annex condition: '+section['reporting_code'])
        if section['particular']:
            items=descriptions(section['body'])
            if reviewed['condition']!='article_description':raise ValueError('Unreviewed particular-product predicate kind')
        else:
            items=[dict(includes=table(section['body']),condition=reviewed['condition'],condition_text=section['prefix'],
                source_scope_sha256=sha(flat(section['prefix']+':'+section['body']).encode()))]
        for item in items:
            result.append({k:section[k] for k in ('locator','reporting_code','target_reporting_codes')}|item)
    if {s['reporting_code'] for s in result}!=set(review['provisions']):raise ValueError('Unaccounted reviewed product-annex provision')
    return result


def floor_inventory(actions,clause):
    """Read both reporting roles and the combined-duty instruction, not a max."""
    text=flat(clause)
    review=json.loads((ROOT/'resources/legal_evidence/section301/forced-labor/reviewed-annexes.json').read_bytes())
    if sha(text.encode())!=review['valuation_clause_sha256']:raise ValueError('Unreviewed note52 valuation clause')
    intro=re.match(r'As provided in headings (.*?), for any good of ',text)
    special=re.search(r'For any good of (.*?) for which a specific or compound rate of duty under column 1-Special is properly claimed, the ad valorem equivalent rate of duty shall be determined in the same manner',text)
    if not intro or not special:raise ValueError('Unparsed note52 General/Special AVE instruction')
    caps={}
    pattern=(r'For headings ([\d., a-z-]+), articles for which the applicable column 1 duty rate is less than ([\d.]+) percent, '
        r'the sum of the column 1 duty rate and the additional ad valorem rate of duty is \2 percent ad valorem')
    for m in re.finditer(pattern,text):
        for code in reporting_codes(m[1]):
            if code in caps:raise ValueError('Duplicated combined-duty instruction')
            caps[code]=float(m[2])/100
    result=[]
    for action in actions:
        if len(action['headings'])==1:continue
        roles={}
        for row in action['headings']:
            m=re.search(r'under column 1 (equal to or greater than|less than) ([\d.]+) percent',row['description'])
            if not m or m[1] in roles:raise ValueError('Unparsed competing country heading roles')
            roles[m[1]]=(row,float(m[2])/100)
        if set(roles)!={'equal to or greater than','less than'}:raise ValueError('Incomplete country floor pair')
        high,hi=roles['equal to or greater than'];low,lo=roles['less than']
        if hi!=lo or caps.get(low['reporting_code'])!=lo:raise ValueError('Original heading/combined-duty instruction conflict')
        if high['native_duty_expressions']['general']!='The duty provided in the applicable subheading' or high['native_duty_expressions']['special']!=high['native_duty_expressions']['general']:
            raise ValueError('Unreviewed no-additional-duty expression')
        rate=re.fullmatch(r'([\d.]+)%',low['native_duty_expressions']['general'])
        if not rate or float(rate[1])/100!=lo or low['native_duty_expressions']['special']!=low['native_duty_expressions']['general']:
            raise ValueError('Unreviewed country floor expression')
        result.append(dict(country_text=action['country_text'],threshold=lo,high_reporting_code=high['reporting_code'],
            low_reporting_code=low['reporting_code'],source_clause_sha256=sha(text.encode()),legal_locator='Original note52(k) and '+high['reporting_code']+'/'+low['reporting_code']))
    if {r['low_reporting_code'] for r in result}!=set(caps) or {c for r in result for c in (r['high_reporting_code'],r['low_reporting_code'])}!=set(reporting_codes(intro[1])):
        raise ValueError('Unaccounted country floor/AVE reporting inventory')
    return dict(actions=sorted(result,key=lambda r:r['country_text']),special_compound_ave_country=special[1],source_clause_sha256=sha(text.encode()))


def reconcile_product_exemptions(original,current,review,require_all_decisions=False):
    def conditions(rows):
        return {(r['reporting_code'],r.get('item','')):(r['condition'],flat(r['condition_text'])) for r in rows}
    if conditions(original)!=conditions(current):raise ValueError('Original/native product-annex condition conflict')
    if review['contract_version']!='sail.section301-forced-labor-annex-reconciliation/v1':raise ValueError('Unknown annex reconciliation contract')
    accepted={r['reporting_code']:r for r in review['decisions']};differences=[]
    for code in sorted({r['reporting_code'] for r in original}):
        source=sorted({p for r in original if r['reporting_code']==code for p in r['includes']})
        copied=sorted({p for r in current if r['reporting_code']==code for p in r['includes']})
        if source==copied:continue
        hashes=dict(original_scope_sha256=sha(json.dumps(source,separators=(',',':')).encode()),native_scope_sha256=sha(json.dumps(copied,separators=(',',':')).encode()))
        decision=accepted.get(code)
        if not decision or any(decision[k]!=v for k,v in hashes.items()) or decision['decision']!='original_published_annex_retained':
            raise ValueError('Unreconciled original/native product-annex scope: '+code)
        differences.append(decision)
    if require_all_decisions and {d['reporting_code'] for d in differences}!=set(accepted):raise ValueError('Stale annex reconciliation decision')
    return differences
