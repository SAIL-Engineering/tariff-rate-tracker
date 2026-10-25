"""Compile the reviewed additional-duty Chapter 98 clause into expressions.

This is a valuation adapter, not an assertion that an importer qualifies for
Chapter 98. Proper claim and CBP agreement are explicit evidence-backed facts.
Each authority must supply its own operative clause. No blanket cross-program
waiver is inferred from the Chapter 98 code or from an aggregate base rate.
"""
import re
from section232_note16_rules import val, fact, op, both, either, negate


def treatment(clause, family='cbp_agreed'):
    text=' '.join(clause.split())
    wording = 'do not' if family == 'section301' else 'shall not'
    if family not in ('cbp_agreed','section301','ieepa_emergency'):
        raise ValueError('Unreviewed Chapter 98 authority family')
    m=re.search(r'The additional dut(?:y|ies) imposed.*?'+wording+r' apply to goods for which entry is properly claimed under a provision of chapter 98.*?except for goods entered under (.*?)(?=For subheadings)',text)
    if not m or (family!='section301' and 'whenever CBP agrees' not in m[0]):
        raise ValueError('Unreviewed Chapter 98 claim predicate')
    if family=='section301' and not re.search(r'chapter 98 of the HTSUS, except',m[0]):
        raise ValueError('Unreviewed Section 301 Chapter 98 claim predicate')
    exceptions=sorted(set(re.findall(r'9802\.00\.\d{2}',m[1])))
    repairs=re.search(r'For subheadings (.*?), the additional dut(?:y|ies) appl(?:y|ies) to the value of repairs, alterations,? or processing performed',text)
    assembly_wording = ('article assembled abroad,' if family=='cbp_agreed' else
        r'article assembled abroad \(in (?:Mexico|Canada|China and Hong Kong)\),' if family=='ieepa_emergency' else 'article')
    assembly=re.search(r'For heading (9802\.00\.\d{2}), the additional dut(?:y|ies) appl(?:y|ies) to the value of the '+assembly_wording+r' less the cost or value of such products of the United States',text)
    if not repairs or not assembly:
        raise ValueError('Unreviewed Chapter 98 valuation clause')
    geography=None
    if family=='ieepa_emergency':
        grammar=(r'For subheadings (?:9802\.00\.\d{2}|[, ]|and)+, the additional duties apply to the value of '
            r'repairs, alterations,? or processing performed \(in (Mexico|Canada|China and Hong Kong)\), '
            r'as described in the applicable subheading\. For heading (9802\.00\.\d{2}), '
            r'the additional duties apply to the value of the article assembled abroad \(in \1\), '
            r'less the cost or value of such products of the United States, as described\.')
        match=re.fullmatch(grammar,text[repairs.start():])
        if not match:raise ValueError('Unreviewed IEEPA Chapter 98 valuation geography or qualifier')
        geography=match[1]
    if family=='section301':
        # A changed jurisdiction, intervening exception or valuation qualifier
        # must not disappear merely because the same four provision numbers
        # still occur. Match the complete operative valuation sentences.
        tail=text[repairs.start():]
        grammar=(r'For subheadings (?:9802\.00\.\d{2}|[, ]|and)+, the additional duties apply to the value of '
                 r'repairs, alterations,? or processing performed abroad, as described in the applicable subheading\. '
                 r'For heading (9802\.00\.\d{2}), the additional duties apply to the value of the article '
                 r'less the cost or value of such products of the United States, as described in heading \1\.')
        if not re.fullmatch(grammar,tail):
            raise ValueError('Unreviewed Section 301 Chapter 98 valuation qualifier')
    repaired=sorted(set(re.findall(r'9802\.00\.\d{2}',repairs[1])))
    if exceptions!=sorted(repaired+[assembly[1]]) or len(repaired)!=3:
        raise ValueError('Chapter 98 exceptions and valuation do not reconcile')
    other=re.sub(r'(?:subheadings?|heading)|9802\.00\.\d{2}|\band\b|[,; .]', '',m[1])
    xxiii='subchapter XXIII of chapter 98 of the tariff schedule' in m[1]
    if xxiii:other=other.replace('subchapterXXIIIofchapter98ofthetariffschedule','')
    if other:
        raise ValueError('Uncompiled Chapter 98 exception: '+other)
    result=dict(repairs=[c.replace('.','') for c in repaired], assembly=assembly[1].replace('.',''),
                subchapter_xxiii_full_value=xxiii)
    if geography:result['geography']=geography
    return result


def compile_valuation(clause, hts, define, claimed, cv, family='cbp_agreed'):
    policy=treatment(clause,family)
    provisions=sorted(set(r['htsno'].replace('.','')[:8] for r in hts
                         if re.fullmatch(r'98\d{2}\.\d{2}\.\d{2}(?:\.\d{2})?',r.get('htsno',''))))
    if not provisions or not set(policy['repairs']+[policy['assembly']]) <= set(provisions):
        raise ValueError('Revision lacks required Chapter 98 provisions')
    code=define('chapter98_provision','Chapter 98 provision (eight digits)','string',
                description='Actual provision claimed, valid in this HTS revision. A declaration alone does not establish eligibility.',choices=provisions)
    accepted=(define('chapter98_properly_claimed_and_cbp_agreed',
                     'Entry properly claimed under Chapter 98 and CBP agrees the provision is appropriate')
              if family!='section301' else define('chapter98_properly_claimed',
                     'Entry properly claimed under the selected Chapter 98 provision'))
    claimed=either(claimed,{'claim':'CHAPTER_98'})
    active=op('if',claimed,accepted,val(False))
    valid=op('eq',code,code)  # fact enum validates identity without repeating the entire HTS inventory in each rule
    repair=both(active, either(*(op('eq',code,val(c)) for c in policy['repairs'])))
    assembly=both(active,op('eq',code,val(policy['assembly'])))
    # Subchapter XXIII is identified from actual revision headings, not a
    # user-selected exemption category or a tariff-rate comparison.
    full=both(active,either(*(op('eq',code,val(c)) for c in provisions if c.startswith('9823')))) if policy['subchapter_xxiii_full_value'] else val(False)
    exempt=op('if',active,both(valid,negate(either(repair,assembly,full))),val(False))
    processing=define('chapter98_repairs_alterations_processing_value','Value of repairs, alterations or processing (USD)','number')
    us=define('chapter98_us_products_value','Cost or value of qualifying U.S. products assembled abroad (USD)','number')
    basis=op('if',repair,processing,op('if',assembly,op('subtract',cv,us),cv))
    if family=='ieepa_emergency':
        # The source limits the repair/assembly value to the named jurisdiction.
        # A generic repairs amount is insufficient for a multi-country operation.
        location=define('ieepa_chapter98_operations_in_covered_origin',
            'The Chapter 98 repair, processing or assembly occurred in the emergency action\'s named origin',
            description='Verify the origin named in the matched source clause. Mixed-country operations need separate reconciliation.')
        basis=op('if',either(repair,assembly),op('if',location,basis,
            {'unresolved_source':'ieepa_chapter98_multiple_or_other_processing_origins'}),basis)
    constraints=[dict(test=op('if',claimed,{'claim':'CHAPTER_98'},val(True)),inputs=['claims'],label='Chapter 98 must be evaluated as a claim across every matched duty action'),
                 dict(test=op('if',active,valid,val(True)),inputs=['chapter98_provision'],label='Provision must be valid in the source revision'),
                 dict(test=op('if',repair,op('lte',processing,cv),val(True)),inputs=[processing['fact'],'customs_value'],label='Repair/processing value cannot exceed entered article value'),
                 dict(test=op('if',assembly,op('lte',us,cv),val(True)),inputs=[us['fact'],'customs_value'],label='U.S. product value cannot exceed assembled article value')]
    return dict(exempt=exempt,adjusted= either(repair,assembly),basis=basis,constraints=constraints,policy=policy)


def overlap_value(valuation, excluded, cv, define, prefix):
    """Intersect two valuation bases; never subtract gross metal from repairs.

    The intersection must be reconciled from shipment evidence. The lower bound
    prevents an asserted disjointness that is impossible for the article value.
    """
    needed=both(valuation['adjusted'],op('gt',excluded,val(0)))
    overlap=define(prefix+'_chapter98_section232_overlap_value',
                   'Section 232-exempt value included in the Chapter 98 dutiable value (USD)','number',
                   description='Reconcile the same value basis. Do not deduct the full article metal or U.S. content from a repairs-only or foreign-assembly value.')
    used=op('if',needed,overlap,excluded)
    test=both(op('lte',overlap,excluded),op('lte',overlap,valuation['basis']),
              op('gte',overlap,op('max',val(0),op('subtract',op('add',excluded,valuation['basis']),cv))))
    constraint=dict(test=op('if',needed,test,val(True)),inputs=[overlap['fact'],'customs_value'],
                    label='Overlap must fit both valuation bases and their shared article value')
    return used,constraint
