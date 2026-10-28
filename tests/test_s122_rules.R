suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/section122_revision.R');source('src/section232_legacy.R');source('src/compile_shipment_rules.R')
products<-c('7318158085','8431310040','7308200035','8505110010','8505110070','3917330000')
f122<-compile_s122_fragment(load_s122_revision_source('2026_rev_4'),products)
f232<-compile_s232_legacy_fragment(load_s232_legacy_source('2026_rev_4'),products)
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$products<-as.list(products);b$countries<-as.list(as.character(read.csv('resources/census_codes.csv')$Code))
b$rules<-list();b$coverage<-list();b$claim_definitions<-list();b$fact_definitions<-list()
b$coverage_requirements<-list('base','section_232','section_122')
b$valid_from<-'2026-02-24T00:00:00-05:00';b$valid_until<-'2026-04-06T00:00:00-04:00'
b$dataset_version<-'synthetic-coverage-s122-conformance';b$revision<-'2026_rev_4'
uncovered<-compose_shipment_rules(b,list(f122,f232));covered<-uncovered
# This fixture attestation deliberately asserts only the tested metal inventory;
# it is not production proof that no other Section 232 actions can apply.
covered$coverage<-list(list(authority='section_232',status='verified',determination='rules',
 source_ids=list(f232$sources[[1]]$id),rule_ids=as.list(vapply(f232$rules,`[[`,character(1),'id'))))
q<-list(customs_value=100,steel_content_value=20,contains_steel=TRUE,
 steel_processed_from_us_metal=FALSE,privileged_ftz_before_20250604=FALSE,
 s122_personal_baggage=FALSE,s122_humanitarian_donation=FALSE,s122_informational_material=FALSE,
 s122_chapter98_claimed=FALSE,s122_ftz_entry=FALSE)
cases<-list();bundles<-list(covered=covered,uncovered=uncovered)
add<-function(name,facts=q,subtotal=18,hts='7318158085',country='5700',at='2026-03-01T12:00:00-05:00',bundle='covered',codes=NULL,missing=NULL,error=NULL) {
 r<-evaluate_shipment_bundle(bundles[[bundle]],hts,country,at,facts)
 if(abs(r$known_subtotal-subtotal)>1e-9) {print(r[c('known_subtotal','missing_inputs','source_errors')]);stop(name)}
 if(!is.null(codes)) stopifnot(setequal(unlist(lapply(Filter(function(c)c$status=='applied'&&c$authority=='section_122',r$components),`[[`,'reporting_codes')),codes))
 if(!is.null(missing)&&!setequal(r$missing_inputs,missing)) stop(name,': missing ',paste(r$missing_inputs,collapse=','))
 if(!is.null(error)) stopifnot(any(grepl(error,r$source_errors,fixed=TRUE)))
 stopifnot(is.null(r$complete_total))
 cases[[length(cases)+1L]]<<-list(name=name,bundle=bundle,hts10=hts,country=country,entry_at=at,facts=facts,
 expected=list(known_subtotal=subtotal,missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors),
 s122_codes=as.list(sort(unique(unlist(lapply(Filter(function(c)c$status=='applied'&&c$authority=='section_122',r$components),`[[`,'reporting_codes')))))))
}
add('steel content is excluded from 122, not the whole article',codes=c('9903.03.01','9903.03.06'),missing=character())
f<-q;f$steel_processed_from_us_metal<-TRUE;f$privileged_ftz_before_20250604<-NULL
add('zero-duty US steel heading still exempts its steel content',f,8,codes=c('9903.03.01','9903.03.06'))
add('missing authority inventory cannot price the 122 remainder',subtotal=10,bundle='uncovered',error='coverage_dependency_unverified:section_232')
f<-q;f$steel_content_value<-0
add('zero metal value leaves full 122 valuation',f,10,codes='9903.03.01')
f<-q;f$steel_content_value<-100
add('full steel content leaves zero 122',f,50,codes='9903.03.06')
f<-q;f$steel_content_value<-101
add('invalid content cannot become negative 122',f,0,missing=c('customs_value','steel_content_value'))
f<-q;f$steel_content_value<-NULL
add('missing content blocks both amounts',f,0,missing='steel_content_value')
f<-q;f$contains_steel<-FALSE
add('candidate with no metal does not claim a portion',f,10,hts='8431310040',codes='9903.03.01')
add('exact ordinary-entry statistical exemption needs no procedural facts',list(unrelated_fixture_flag=TRUE,s122_ftz_entry=FALSE),0,hts='8505110070',codes='9903.03.03',missing=character())
add('adjacent suffix pays 122',q,10,hts='8505110010',codes='9903.03.01')
f<-q;f$s122_loaded_and_final_transit_before_start<-TRUE
add('transit relief before exact cutoff',f,10,at='2026-02-28T00:00:59-05:00',codes='9903.03.02')
add('transit relief ends at exact cutoff',f,18,at='2026-02-28T00:01:00-05:00',codes=c('9903.03.01','9903.03.06'))
f<-q;f$claims<-list('USMCA');f$s122_usmca_entered_free<-TRUE
add('actual duty-free USMCA entry removes 122 only',f,10,country='1220',codes='9903.03.07')
f$s122_usmca_entered_free<-FALSE
add('USMCA label alone cannot establish duty-free entry',f,18,country='1220',codes=c('9903.03.01','9903.03.06'))
f<-q;f$s122_gn6_civil_aircraft<-TRUE
add('civil aircraft condition gives product exemption',f,0,hts='3917330000',codes='9903.03.05')
f$s122_gn6_civil_aircraft<-FALSE
add('civil aircraft association alone is not exemption',f,10,hts='3917330000',codes='9903.03.01')
f<-q;f$modeled_share<-0;f$assembly_credit<-100000;f$modeled_s122_exempt_share<-1
add('model values cannot change shipment',f,18)
f<-q;f$s122_chapter98_claimed<-TRUE
add('Chapter98 requires a confirmed claim and provision',f,10,missing=c('chapter98_properly_claimed_and_cbp_agreed','chapter98_provision'))
cat(length(cases),'Section 122 cross-program cases passed\n')
# Independent action fixtures verify heading-based relief and exact legal clocks.
# Their rates and coverage are synthetic; the Section 122 interaction is sourced.
b$valid_from<-'2026-02-24T00:00:00-05:00';b$valid_until<-'2026-08-01T00:00:00-04:00'
sid<-'synthetic-interaction';b$sources<-c(b$sources,list(list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/interaction',citation='Synthetic action fixture; no all-authority legal attestation')))
mk<-function(id,code,amount,from=NULL,when=list(value=TRUE)) list(id=id,action_id=id,authority='section_232',kind='duty',verification='verified',source_ids=list(sid),reporting_codes=list(code),formula=list(value=amount),scope=list(from=from),when=when)
make<-function(rule) {
 bb<-b;bb$rules<-list(rule);bb$coverage<-list(list(authority='section_232',status='verified',source_ids=list(sid),determination='rules',rule_ids=list(rule$id)))
 compose_shipment_rules(bb,list(f122))
}
bundles$zero<-make(mk('zero','9903.82.02',0,'2026-04-06T00:01:00-04:00'))
add('first April minute still uses original interaction',q,10,at='2026-04-06T00:00:59-04:00',bundle='zero',codes='9903.03.01')
add('April amendment exempts listed zero-dollar heading',q,0,at='2026-04-06T00:01:00-04:00',bundle='zero',codes='9903.03.06')
add('June snapshot omission cannot delete unchanged 82.02',q,0,at='2026-06-08T00:01:00-04:00',bundle='zero',codes='9903.03.06')
bundles$taiwan<-make(mk('taiwan','9903.94.66',0,'2026-05-01T00:01:00-04:00'))
add('Taiwan amendment not prematurely applied',q,10,at='2026-05-01T00:00:59-04:00',bundle='taiwan',country='5830',codes='9903.03.01')
add('Taiwan zero floor relief begins at legal instant',q,0,at='2026-05-01T00:01:00-04:00',bundle='taiwan',country='5830',codes='9903.03.06')
add('last legal minute before expiry retains exemption',q,0,at='2026-07-24T00:00:59-04:00',bundle='taiwan',country='5830',codes='9903.03.06')
add('expired 122 does not survive retained headings',q,0,at='2026-07-24T00:01:00-04:00',bundle='taiwan',country='5830',codes=character())
bundles$unknown<-make(mk('unknown','9903.94.67',15,'2026-05-01T00:01:00-04:00'))
add('Taiwan reconciliation cannot cover an unrelated origin',q,15,at='2026-05-01T00:01:00-04:00',bundle='unknown',error='unlisted_section232_action')
bundles$unknown_zero<-make(mk('unknown-zero','9903.94.67',0,'2026-05-01T00:01:00-04:00'))
add('unlisted zero-duty decision cannot establish full-value 122',q,0,at='2026-05-01T00:01:00-04:00',bundle='unknown_zero',error='unlisted_section232_action')
# Paragraph 4 and the independently inserted note 33(u)/heading table establish
# the Taiwan interaction, without rewriting the malformed note 2 reference.
add('Taiwan valid substantive heading exempts whole article',q,15,country='5830',at='2026-05-01T00:01:00-04:00',bundle='unknown',codes='9903.03.06')
add('Taiwan reconciliation starts at original entry instant',q,10,country='5830',at='2026-05-01T00:00:59-04:00',bundle='unknown',codes='9903.03.01')
add('independent Taiwan decision survives June amendment',q,15,country='5830',at='2026-06-08T00:01:00-04:00',bundle='unknown',codes='9903.03.06')
add('independent Taiwan relief ends with Section122',q,15,country='5830',at='2026-07-24T00:01:00-04:00',bundle='unknown',codes=character())
add('valid heading from wrong origin is not independently exempt',q,0,country='5700',at='2026-05-01T00:01:00-04:00',bundle='taiwan',error='unlisted_section232_action')
bundles$semiconductor<-make(mk('semiconductor','9903.79.01',0))
add('zero semiconductor amount remains named whole-article relief',q,0,bundle='semiconductor',codes='9903.03.06')
# A Section 232 claim revives 122 rather than being subtracted from a finished sum.
bb<-b;bb$rules<-list(mk('claimable','9903.79.01',25,when=list(op='not',args=list(list(claim='synthetic232claim')))))
bb$rules[[1]]$grant_id<-'synthetic';bb$rules[[1]]$grant_snapshot_id<-'synthetic-only'
bb$claim_definitions<-list(list(id='synthetic232claim',label='Synthetic relief',rule_ids=list('claimable'),candidate_rule_ids=list('claimable'),source_ids=list(sid)))
bb$coverage<-list(list(authority='section_232',status='verified',source_ids=list(sid),determination='rules',rule_ids=list('claimable')))
bundles$claim<-compose_shipment_rules(bb,list(f122));f<-q;f$claims<-list('synthetic232claim')
add('Section232 claim revives full 122',f,10,bundle='claim',codes='9903.03.01')
add('unclaimed action exempts full article from 122',q,25,bundle='claim',codes='9903.03.06')
shuffled<-f122;shuffled$rules<-rev(shuffled$rules);shuffled$sources<-rev(shuffled$sources)
stopifnot(identical(.shipment_canonical(compose_shipment_rules(bb,list(shuffled))),.shipment_canonical(bundles$claim)))
# Coverage keys are not caller facts, and absent or stale attestations never pass.
bundles$claim_uncovered<-bundles$claim;bundles$claim_uncovered$coverage<-list();f$authority_covered<-TRUE
add('user cannot assert missing authority coverage',f,0,bundle='claim_uncovered',error='coverage_dependency_unverified:section_232')
f<-q;f$contains_aluminum<-TRUE;f$aluminum_content_value<-10;f$aluminum_processed_from_us_metal<-FALSE
f$aluminum_primary_smelted_or_cast_russia<-FALSE;f$s122_content_values_disjoint<-TRUE
add('mixed metal values leave only the remaining portion',f,22,hts='7308200035',codes=c('9903.03.01','9903.03.06'))
f$s122_content_values_disjoint<-FALSE
add('overlapping content valuations cannot price 122',f,15,hts='7308200035',missing='s122_content_values_disjoint')
bundles$disputed_zero<-make(mk('disputed-zero','9903.82.24',0,'2026-06-08T00:01:00-04:00'))
add('reconciled June extension exempts its zero-duty heading',q,0,at='2026-06-08T00:01:00-04:00',bundle='disputed_zero',codes='9903.03.06')
add('June extension is not applied a second early',q,10,at='2026-06-08T00:00:59-04:00',bundle='disputed_zero',codes='9903.03.01')
bundles$april23<-make(mk('april23','9903.82.18',0,'2026-04-23T00:01:00-05:00'))
add('April23 printed standard-time boundary honored before',q,10,at='2026-04-23T01:00:59-04:00',bundle='april23',codes='9903.03.01')
add('April23 printed standard-time boundary honored at',q,0,at='2026-04-23T01:01:00-04:00',bundle='april23',codes='9903.03.06')
bb$rules[[1]]$grant_id<-NULL;bb$rules[[1]]$grant_snapshot_id<-NULL
bundles$unreviewed_claim<-compose_shipment_rules(bb,list(f122));f<-q;f$claims<-list('synthetic232claim')
add('unreviewed 232 claim is not granted an unchanged effect',f,0,bundle='unreviewed_claim',error='claim_not_priced:synthetic232claim')
# Source-defined Chapter 98 valuation, with an explicitly empty synthetic 232
# inventory. Other authorities' Chapter 98 entitlement is not inferred here.
bb<-b;bb$rules<-list();bb$claim_definitions<-list()
bb$coverage<-list(list(authority='section_232',status='verified',source_ids=list(sid),determination='no_applicable_rules',rule_ids=list()))
bundles$chapter98<-compose_shipment_rules(bb,list(f122))
f<-q;f$s122_chapter98_claimed<-TRUE;f$claims<-list('CHAPTER_98');f$chapter98_properly_claimed_and_cbp_agreed<-TRUE;f$chapter98_provision<-'98010010'
add('properly claimed returned goods exempt only this authority',f,0,bundle='chapter98',codes=character(),missing=character())
f$chapter98_provision<-'98230101';add('122 Chapter98 rule does not import 338 XXIII exception',f,0,bundle='chapter98',codes=character())
f$chapter98_provision<-'98020040';f$chapter98_repairs_alterations_processing_value<-30
add('122 repairs value',f,3,bundle='chapter98',codes='9903.03.01',missing=character())
f$chapter98_provision<-'98020050';add('122 alterations value',f,3,bundle='chapter98')
f$chapter98_provision<-'98020060';add('122 processing value',f,3,bundle='chapter98')
f$chapter98_provision<-'98020080';f$chapter98_us_products_value<-70;add('122 foreign assembly less qualifying US value',f,3,bundle='chapter98')
f$chapter98_us_products_value<-101;add('122 assembly values must reconcile',f,0,bundle='chapter98',missing=c('chapter98_us_products_value','customs_value'))
f$chapter98_us_products_value<-70;f$chapter98_provision<-'98999999';add('invalid Chapter98 provision cannot become exemption',f,0,bundle='chapter98',missing='chapter98_provision')
f$chapter98_provision<-'98020040';f$chapter98_properly_claimed_and_cbp_agreed<-FALSE;add('rejected Chapter98 claim leaves ordinary basis',f,10,bundle='chapter98')
f$chapter98_properly_claimed_and_cbp_agreed<-TRUE;f$claims<-NULL
add('Chapter98 valuation requires stack-wide claim evaluation',f,0,bundle='chapter98',missing='claims')
f$claims<-list('CHAPTER_98')
add('uncompiled Chapter98 effect on 232 is not silently unchanged',f,0,bundle='covered',error='claim_not_priced:CHAPTER_98')
# Counterfactual reviewed 232 action isolates the intersection of two bases.
rr<-mk('adjusted232','9903.81.89',10);bb$rules<-list(rr)
bb$coverage<-list(list(authority='section_232',status='verified',source_ids=list(sid),determination='rules',rule_ids=list(rr$id)))
bb$claim_definitions<-list(list(id='CHAPTER_98',label='Chapter 98',rule_ids=list(rr$id),source_ids=list(sid)))
bundles$chapter98_overlap<-compose_shipment_rules(bb,list(f122))
f$s122_chapter98_section232_overlap_value<-5
add('122 subtracts only metal value inside repairs basis',f,12.5,bundle='chapter98_overlap',codes=c('9903.03.01','9903.03.06'))
f$s122_chapter98_section232_overlap_value<-NULL
add('unreconciled repairs-metal overlap remains missing',f,10,bundle='chapter98_overlap',missing='s122_chapter98_section232_overlap_value')
f$s122_chapter98_section232_overlap_value<-21
add('overlap cannot exceed metal content',f,10,bundle='chapter98_overlap',missing=c('s122_chapter98_section232_overlap_value','customs_value'))
f$chapter98_repairs_alterations_processing_value<-90;f$s122_chapter98_section232_overlap_value<-5
add('impossible disjoint valuation cannot understate the intersection',f,10,bundle='chapter98_overlap',missing=c('s122_chapter98_section232_overlap_value','customs_value'))
if('--emit'%in%commandArgs(TRUE)) jsonlite::write_json(list(bundles=bundles,cases=cases),'tests/fixtures/shipment/section122.json',auto_unbox=TRUE,null='null',digits=NA)
cat(length(cases),'total Section 122 interaction and temporal cases passed\n')
