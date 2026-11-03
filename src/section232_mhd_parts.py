"""Original MHD part decisions and certified-use elections, not sector averages.

The annex supplies mixed HTS8/10 scope and actual reporting roles. Its successive
metal nonstacking amendments supply legal windows independently of HTS releases.
This fragment does not attest the complete Section232 inventory.
"""
from __future__ import annotations
import argparse
import copy
import csv
from datetime import datetime
from functools import lru_cache
from build_contract import audit_until
import json
from pathlib import Path
import re
import subprocess

from section301_sources import sha, unique_span, verify_revision_header
from section232_stacking import note, reporting_codes, amendment,reported,russian_aluminum_codes,russian_aluminum_stacking_source
from section232_note16_rules import val, fact, op, both, either, negate
from ieepa_fentanyl_sources import verified_source, windows
from shipment_base_sources import extract_rows

ROOT=Path(__file__).resolve().parents[1]
EVIDENCE=ROOT/'resources/legal_evidence/section232/vehicle-parts'
PRODUCT=r'(?<![\d.])(?:\d{4}\.\d{2}\.\d{4}|\d{4}\.\d{2}\.\d{2})(?![\d.])'


def semantic(text):
    return re.sub(r'[^a-z0-9%]','',text.lower())


def signature(x):
    return sha(json.dumps(x,sort_keys=True,separators=(',',':')).encode())


def product_table(clause):
    tail=clause.split('this subdivision:',1)
    if len(tail)!=2:raise ValueError('MHD parts scope introduction missing')
    codes=re.findall(PRODUCT,tail[1])
    if not codes or re.sub(PRODUCT,'',tail[1]).strip():raise ValueError('Unparsed MHD parts scope table')
    return sorted({c.replace('.','') for c in codes})


def exclusion_clause(text):
    starts=list(re.finditer(r'\((\d+)\) the additional duties',text))
    if [int(m[1]) for m in starts]!=list(range(1,len(starts)+1)) or not starts:
        raise ValueError('Unreviewed MHD part exclusion structure')
    return dict(prefix=text[:starts[0].start()].strip(),rows=[
        text[m.end():starts[i+1].start() if i+1<len(starts) else len(text)].strip().rstrip('; .')
        for i,m in enumerate(starts)])


def add_source(s,sources,artifacts):
    p=Path(s['path']);p=p if p.is_absolute() else ROOT/p
    if sha(p.read_bytes())!=s['sha256']:raise ValueError('Vehicle parts evidence hash mismatch: '+s['id'])
    if 'original_pdf_path' in s:
        if sha((ROOT/s['original_pdf_path']).read_bytes())!=s['original_pdf_sha256']:
            raise ValueError('Vehicle parts original PDF changed')
        pid=s['id']+'-original-pdf'
        sources.append(dict(id=pid,sha256=s['original_pdf_sha256'],url=s['url'],citation=s['citation'],status='verified'))
        artifacts.append(dict(source_id=pid,path=str(ROOT/s['original_pdf_path']),sha256=s['original_pdf_sha256']))
    sources.append({k:s[k] for k in ('id','sha256','url','citation')}|dict(status='verified'))
    artifacts.append(dict(source_id=s['id'],path=str(p),sha256=s['sha256']))
    return p.read_text() if p.suffix!='.pdf' else subprocess.check_output(['pdftotext','-layout',str(p),'-'],text=True)


@lru_cache(maxsize=1)
def load_history():
    sources=[];artifacts=[]
    original_meta=json.loads((EVIDENCE/'original-source.json').read_bytes())
    reviewed=json.loads(add_source(original_meta,sources,artifacts))
    vehicle_review=json.loads(add_source(json.loads((EVIDENCE/'mhd-vehicles-source.json').read_bytes()),sources,artifacts))
    vehicle_scopes={key:product_table(vehicle_review['clauses'][letter]) for key,letter in [('vehicles','b'),('buses','c')]}
    body,meta=verified_source('2025-19639');add_source(meta,sources,artifacts)
    # Clause9 adopts the automobile stacking rule. Its original aluminum
    # action includes Proclamation10522, not just illustrative metal headings.
    add_source(russian_aluminum_stacking_source(),sources,artifacts)
    begin=windows(unique_span(body,r'^\(1\)',r'^\(2\)'))['valid_from']
    first=' '.join(unique_span(body,r'^\(1\)',r'^\(2\)').split())
    rate=re.search(r'subject to a ([\d.]+) percent ad valorem duty rate',first)
    if not begin or not rate:raise ValueError('Missing original MHD part rate or clock')
    clause12=' '.join(unique_span(body,r'^\(12\)',r'^\(13\)').split())
    if not all(s in clause12 for s in ('An importer of record may declare','the part cannot be presently subject',
        'Chapters 72, 73, or 76','production or repair activity in the United States','certification from the importer of record')):
        raise ValueError('Unreviewed certified vehicle part election')
    clauses=reviewed['note38'];scope=product_table(clauses['i'])
    offset_meta=json.loads((EVIDENCE/'2026-09782-source.json').read_bytes())
    offset_text=' '.join(add_source(offset_meta,sources,artifacts).split())
    offset_match=re.search(r'inserting the following in lieu thereof: ``(Subject to a manufacturer\x27s import adjustment offset amount.*?)\x27\x27',offset_text)
    if not offset_match:raise ValueError('Missing original amended MHD offset scope introduction')
    offset_intro=offset_match[1].split('this subdivision:',1)[0]
    cbp=add_source(json.loads((EVIDENCE/'CBP-mhdv-source.json').read_bytes()),sources,artifacts)
    if 'self-certified by importers' not in cbp or 'are eligible to use HTS 9903.74.10' not in cbp:
        raise ValueError('Unreviewed certified MHD USMCA interpretation')
    def role(k):
        m=re.search(r'Heading (9903\.\d{2}\.\d{2}) applies to',clauses[k])
        if not m:raise ValueError('Missing original MHD part reporting role')
        return m[1]
    listed=re.search(r'heading (9903\.\d{2}\.\d{2}) apply to',clauses['i'])
    if not listed:raise ValueError('Missing original listed MHD part heading')
    roles=dict(listed=listed[1],certified=role('j'),usmca=role('k'),non_part=role('l'))
    excluded_chapters=re.search(r'HTSUS chapters (\d{2}), (\d{2}) or (\d{2})',clauses['j'])
    if not excluded_chapters or 'subdivision (g) of U.S. note 33' not in clauses['j']:
        raise ValueError('Unreviewed certified MHD exclusions')
    by_code={r['htsno']:r for r in reviewed['mhd_headings']}
    for k,c in roles.items():
        row=by_code.get(c)
        expected='The duty provided in the applicable subheading'+(' + '+rate[1]+'%' if k in ('listed','certified') else '')
        if not row or any(semantic(row.get(f,''))!=semantic(expected) for f in ('general','special','other')):
            raise ValueError('Original MHD part heading table/rate disagreement')
    ordinary=exclusion_clause(clauses['h'])
    if len(ordinary['rows'])!=8:raise ValueError('Incomplete original MHD part nonstacking list')
    periods=[dict(from_=begin,clause=copy.deepcopy(ordinary))]
    april_meta=json.loads((EVIDENCE/'april-source.json').read_bytes())
    april=add_source(april_meta,sources,artifacts)
    m=re.search(r'"the additional duties (.*?)"', ' '.join(april.split()))
    if not m or 'deleting subdivisions (1) through (5)' not in april or 'renumbering subdivisions (6) through (8) as (2) through (4)' not in april:
        raise ValueError('Unreviewed April MHD part replacement')
    a_meta=next(s for s in json.loads((ROOT/'resources/legal_evidence/section232/civil-aircraft/sources.json').read_bytes())['sources'] if s['role']=='proclamation_body')
    a=add_source(a_meta,sources,artifacts)
    at=windows(unique_span(a,r'\(1\) Effective',r'\(2\)'))['valid_from']
    state=copy.deepcopy(ordinary);state['rows']=[m[1].rstrip('; .')]+state['rows'][5:]
    periods.append(dict(from_=at,clause=copy.deepcopy(state)))
    inventory=json.loads((ROOT/'resources/legal_evidence/section122/interactions/review.json').read_bytes())['sources']
    april23=add_source(next(s for s in inventory if s['id']=='FR-2026-07987-txt'),sources,artifacts)
    from section232_semiconductors import canonical,at as instant
    clock=re.search(r'12:01 a\.m\. eastern standard time on (\w+ \d+, \d{4})',canonical(april23))
    match=re.search(r'8\. U\.S\. note 38 is modified by deleting ``(.*?)\x27\x27.*?inserting ``(.*?)\x27\x27',canonical(april23))
    if not match or not clock:raise ValueError('Missing original April23 MHD operation/clock')
    old,new=match.groups()
    # Punctuation changes are typographic only; replacement operands must name
    # exactly the predecessor range, not an invented widening from a later book.
    def replace_range(old,new):
        expression=r'9903\.\d{2}\.\d{2}\s*[-–—]+\s*9903\.\d{2}\.\d{2}'
        prior=re.findall(expression,state['rows'][0])
        old=re.sub(r'[-–—]+','-',old);new=re.sub(r'[-–—]+','-',new)
        if len(prior)!=1 or reporting_codes(prior[0])!=reporting_codes(old):raise ValueError('MHD amendment predecessor mismatch')
        state['rows'][0]=state['rows'][0].replace(prior[0],new)
    replace_range(old,new);periods.append(dict(from_=instant(clock[1],standard=True),clause=copy.deepcopy(state)))
    june=add_source(next(s for s in inventory if s['id']=='FR-2026-11314-reviewed-transcription'),sources,artifacts).split('B. Effective')[0]
    june=' '.join(june.split())
    match=re.search(r'U\.?S\.?S?\. note 38 is modified by deleting [“"](.*?)[”"].*?inserting [“"](.*?)[”"]',june)
    clock=re.search(r'12:01 a\.m\. eastern daylight time on (\w+ \d+, \d{4})',june)
    if not match or not clock:raise ValueError('Missing original June MHD operation/clock')
    replace_range(*match.groups());periods.append(dict(from_=instant(clock[1]),clause=copy.deepcopy(state)))
    until=audit_until()
    for i,p in enumerate(periods):
        p['until']=periods[i+1]['from_'] if i+1<len(periods) else until
        p['targets']=sorted({c for row in p['clause']['rows'] for c in reporting_codes(row)})
        if not p['from_'] or datetime.fromisoformat(p['from_'])>=datetime.fromisoformat(p['until']):raise ValueError('Invalid MHD legal window')
    return dict(from_=begin,until=until,rate=float(rate[1])/100,roles=roles,clauses=clauses,scope=scope,
        offset_intro=offset_intro,
        vehicle_review=vehicle_review,vehicle_scopes=vehicle_scopes,
        excluded_chapters=list(excluded_chapters.groups()),periods=periods,reviewed=reviewed,sources=sources,source_artifacts=artifacts)


def reconcile(clauses,headings,h):
    if not clauses:
        if headings:raise ValueError('MHD headings without note38')
        return 'pre_action_native_snapshot'
    for k in 'jkl':
        if semantic(clauses.get(k,''))!=semantic(h['clauses'][k]):raise ValueError('Unreviewed MHD '+k+' conditions')
    for k in 'bc':
        if semantic(clauses.get(k,''))!=semantic(h['vehicle_review']['clauses'][k]):raise ValueError('Unreviewed MHD vehicle exclusion scope')
    if product_table(clauses.get('i',''))!=h['scope']:raise ValueError('Unreviewed MHD part scope change')
    intro=clauses['i'].split('this subdivision:',1)[0]
    ordinary=h['clauses']['i'].split('this subdivision:',1)[0]
    offset=h['offset_intro']
    if semantic(intro) not in (semantic(ordinary),semantic(offset)):
        raise ValueError('Unreviewed MHD scope qualification')
    parsed=exclusion_clause(clauses['h'])
    signatures=[(semantic(p['clause']['prefix']),[semantic(r) for r in p['clause']['rows']]) for p in h['periods']]
    if (semantic(parsed['prefix']),[semantic(r) for r in parsed['rows']]) not in signatures:
        raise ValueError('Unreconciled MHD nonstacking amendment')
    current={r['htsno']:r for r in headings}
    for row in h['reviewed']['mhd_headings']:
        now=current.get(row['htsno'])
        if not now or any(semantic(now.get(f,''))!=semantic(row[f]) for f in ('description','general','special','other')):
            raise ValueError('Unreviewed MHD part reporting expression')
    return 'original_and_amendments_reconciled'


def assert_native_presence(revision,clauses,h):
    calendar=[r for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()) if r['revision']==revision]
    if len(calendar)!=1:raise ValueError('Missing MHD source calendar identity')
    day=calendar[0]['policy_effective_date']
    if day=='NA':day=calendar[0]['effective_date']
    if not clauses and day>=h['from_'][:10]:
        raise ValueError('MHD headings disappear after commencement; reconcile a legal termination or new reporting action')


def extract(revision):
    if not re.fullmatch(r'202[56]_(?:basic|rev_\d+)',revision):raise ValueError('Identified MHD revision required')
    pdf=ROOT/f'data/us_notes/chapter99_{revision}.pdf';hts=ROOT/f'data/hts_archives/hts_{revision}.json'
    raw=subprocess.check_output(['pdftotext','-layout',str(pdf),'-'],text=True);verify_revision_header(raw,revision)
    rows=json.loads(hts.read_bytes());hs=[{k:r.get(k,'') for k in ('htsno','description','general','special','other')}
        for r in rows if re.fullmatch(r'9903\.74\.\d{2}',r.get('htsno',''))]
    c=note(raw,38) if hs else {};h=load_history();state=reconcile(c,hs,h)
    assert_native_presence(revision,c,h)
    auto=note(raw,33)
    from section232_autos import native_scope,load_history as auto_history
    # Original exclusions are cross-note references, not a user assertion that
    # the same article is outside another program's listed scope.
    automobile=auto_history();original_auto=automobile['parts']['prefixes']
    if 'g' in auto and native_scope(auto['g'])!=original_auto:raise ValueError('Unreconciled auto exclusion for MHD certified parts')
    release=revision.replace('_rev_','HTSRev').replace('_basic','HTSBasic')
    src=[dict(id=f'USITC-{revision}-mhd-parts-'+p.suffix[1:],path=str(p),sha256=sha(p.read_bytes()),
        url='https://hts.usitc.gov/reststop/'+(f'file?release={release}&filename=Chapter%2099' if p.suffix=='.pdf' else f'exportList?release={release}&exportFormat=JSON'),
        citation='Native note38(a)-(l), cross-note33(g) exclusions and actual MHD reporting expressions.') for p in (pdf,hts)]
    x=dict(revision=revision,reconciliation=state,clauses=c,headings=hs,auto_scope=original_auto,
        auto_vehicle_scope=automobile['vehicles']['prefixes'],
        russian_reporting_codes=russian_aluminum_codes(rows),
        products=[p['hts10'] for p in extract_rows(rows)['products']],sources=src,
        chapter98_provisions=sorted({r['htsno'].replace('.','')[:8] for r in rows if re.fullmatch(r'98\d{2}\.\d{2}\.\d{2}(?:\.\d{2})?',r.get('htsno',''))}))
    x['integrity']=signature(x);return x


def memberships(h,products,auto_scope):
    listed=[p for p in products if any(p.startswith(s) for s in h['scope'])]
    certified=[p for p in products if p[:2] not in h['excluded_chapters'] and p not in listed and not any(p.startswith(s) for s in auto_scope)
        and not any(p.startswith(s) for s in h['vehicle_scopes']['buses'])]
    return dict(listed=sorted(set(listed)),certified=sorted(set(certified)))


def compile_rules(x,products):
    y=copy.deepcopy(x);integrity=y.pop('integrity',None)
    if signature(y)!=integrity:raise ValueError('MHD extraction changed after reconciliation')
    if set(products)-set(x['products']):raise ValueError('MHD product outside native revision')
    h=load_history();sources=copy.deepcopy(h['sources']);artifacts=copy.deepcopy(h['source_artifacts'])
    for s in x['sources']:add_source(s,sources,artifacts)
    ids=[s['id'] for s in sources];facts={};rules=[];relations=[]
    def define(name,label,kind='boolean',choices=None):
        d=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':d.update(minimum=0,unit='USD')
        if choices:d['enum']=choices
        facts[name]=d;return fact(name)
    cv=define('customs_value','Full article customs value (USD)','number')
    use=define('s232_mhd_parts_use','Article actually is a part of a medium- or heavy-duty vehicle')
    eligible=define('s232_mhd_usmca_eligible','Goods actually qualify for preferential tariff treatment under USMCA')
    kit=define('s232_mhd_knockdown_kit_or_compilation','Entry is a MHD knock-down kit or equivalent parts compilation as determined by CBP')
    election=define('s232_vehicle_parts_certification','IOR certified declaration under Proclamation10984 clause12',
        'string',['none','automobile','mhd'])
    # The certification records the elected legal path, not merely hypothetical
    # capacity to be used as a part. Part identity/use remains a separate fact.
    certified=op('eq',election,val('mhd'))
    auto_vehicle=define('s232_auto_passenger_vehicle','Article is a passenger vehicle or light truck as defined by U.S. note33(a)')
    mhd_vehicle=define('s232_mhd_vehicle','Article is a medium- or heavy-duty vehicle under the matched original action')
    ch=define('chapter98_properly_claimed','Entry properly claimed under the selected Chapter98 provision')
    code=define('chapter98_provision','Chapter98 provision (eight digits)','string',x['chapter98_provisions'])
    full=re.search(r'except that duties under subheading (9802\.\d{2}\.\d{2}) shall be assessed based upon the full value',h['clauses']['h'])
    if not full:raise ValueError('Missing MHD Chapter98 valuation exception')
    chapter98=op('if',{'claim':'CHAPTER_98'},op('if',ch,op('if',op('eq',code,val(full[1].replace('.',''))),val(True),
        {'unresolved_source':'mhd_parts_chapter98_selected_provision_terms_and_valuation'}),
        {'unresolved_source':'mhd_parts_chapter98_entitlement'}),val(True))
    define('ieepa_ftz_entry','Entry from a foreign trade zone')
    groups=memberships(h,products,x['auto_scope'])
    group_specs=[]
    for kind,ps in groups.items():
        for possible_vehicle in (False,True):
            for possible_mhd in (False,True):
                group_specs.append((kind,[p for p in ps if (kind=='certified' and any(p.startswith(s) for s in x['auto_vehicle_scope']))==possible_vehicle and
                    any(p.startswith(s) for s in h['vehicle_scopes']['vehicles'])==possible_mhd],possible_vehicle,possible_mhd))
    for kind,ps,possible_vehicle,possible_mhd in group_specs:
        if not ps:continue
        path=use if kind=='listed' else op('if',{'claim':'SECTION_232_CERTIFIED_MHD_PARTS'},op('if',certified,use,val(False)),val(False))
        if possible_vehicle:path=op('if',auto_vehicle,val(False),path)
        identity=negate(mhd_vehicle) if possible_mhd else val(True)
        exception=op('if',eligible,negate(kit),val(False))
        for period in h['periods']:
            scope=dict(hts_exact=ps,**{'from':period['from_'],'until':period['until']})
            for role,when,formula,subject in [
                (kind,both(path,negate(exception)),op('if',{'claim':'SECTION_232_MHD_IMPORT_OFFSET'},
                    {'unresolved_source':'mhd_parts_approved_offset_allocation_and_entry_application'},op('multiply',cv,val(h['rate']))),True),
                ('usmca',both(path,exception),val(0),True)]+([
                ('non_part',negate(path),val(0),False)] if kind=='listed' else []):
                rid=f'mhd_parts_{x["revision"]}_{len(rules)}'
                r=dict(id=rid,action_id='s232_mhd_parts',authority='section_232',kind='duty',verification='verified',
                    scope=scope,when=both(identity,when,chapter98),formula=formula,reporting_codes=[h['roles'][role]],source_ids=ids,
                    legal_locator='Proclamation10984 clauses1,3,9,12; AnnexI note38(h)-(l); Proclamation11021/11032 and April23 amendment')
                if not subject and formula==val(0):r['reporting_only']=True
                rules.append(r)
                if subject:relations.append(dict(id=rid+'_source_nonstacking',effect='suppress',when_rule_applies=rid,
                    trigger_test='applicability',target_reporting_codes=period['targets'],source_ids=ids))
                if subject and x['russian_reporting_codes']:relations.append(dict(id=rid+'_russian_aluminum_nonstacking',effect='suppress',when_rule_applies=rid,
                    trigger_test='applicability',target_reporting_codes=x['russian_reporting_codes'],source_ids=ids))
    rids=[r['id'] for r in rules]
    # Bind against each consumer's scope/window during composition. A global
    # OR of every source rule would grow with the complete revision inventory.
    exempt=reported([h['roles']['usmca']])
    certified_ids=[r['id'] for r in rules if any(p in groups['certified'] for p in r['scope']['hts_exact'])]
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='s232_mhd_parts_'+x['revision'],
        supported_from='2025-01-01T00:00:00-05:00',supported_until=h['until'],sources=sources,source_artifacts=artifacts,
        compiler_sha256=sha(Path(__file__).read_bytes()),rules=rules,relations=relations,coverage=[],fact_definitions=facts,
        claim_definitions=[dict(id=c,label=l,rule_ids=rids,source_ids=ids) for c,l in [('USMCA','USMCA'),
            ('COLUMN1_SPECIAL','Selected Column 1 Special preference'),('CHAPTER_98','Chapter 98'),
            ('SECTION_232_MHD_IMPORT_OFFSET','Medium/heavy-duty vehicle import-adjustment offset')]]+
            ([dict(id='SECTION_232_CERTIFIED_MHD_PARTS',label='Certified U.S. MHD production/repair parts',rule_ids=rids,candidate_rule_ids=certified_ids,source_ids=ids)] if certified_ids else []) if rules else [],
        derived_facts={name:dict(expression=exempt,source_ids=ids) for name in
            ('s232_usmca_mhd_parts_not_kits','s122_usmca_mhd_parts_not_kits','s338_usmca_mhd_parts_not_kits')},
        unchanged_claims=([dict(id='mhd_parts_section301_independence',claim_authority='section_301',
            candidate_required_fields=['exclusion_claim_id'],target_rule_ids=rids,source_ids=ids)]+
            ([dict(id='mhd_parts_certified_reevaluation',effect='reevaluate',claim_authority='section_232',
                claim_ids=['SECTION_232_CERTIFIED_MHD_PARTS'],target_authorities=['base','section_201','section_232','section_301',
                    'ieepa_fentanyl','ieepa_reciprocal','ieepa_other','section_122','section_338','adcvd','other_chapter99'],source_ids=ids)] if certified_ids else [])) if rids else [],
        entry_context=dict(mode='ordinary_only',fact='ieepa_ftz_entry',source_ids=ids,
            unresolved_source='mhd_parts_ftz_admission_status_and_action_history'),
        candidate_memberships=groups,
        candidate_scope_matches=dict(listed=[dict(hts10=p,scope_code=prefix,scope_grain='exact_hts10' if len(prefix)==10 else 'prefix')
            for p in groups['listed'] for prefix in h['scope'] if p.startswith(prefix)]),
        snapshot_reconciliation=x['reconciliation'],
        limitations=['No complete Section232 attestation. MHD vehicles/buses are separate actions.',
            'Chapter98 provisions other than the express full-value9802.00.60 exception and approved offset allocation remain explicit executable questions.'])


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    a=p.parse_args();x=json.loads(Path(a.input).read_bytes())
    Path(a.output).write_text(json.dumps(compile_rules(extract(x['revision']),x['products']),separators=(',',':'))+'\n')
