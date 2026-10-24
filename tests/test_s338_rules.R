suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/section338_revision.R');source('src/compile_shipment_rules.R')
products<-c('2203000030','0402101000','8537109130','8537109120','7608100030','9403200090','2208306085','2208306075')
fragment<-compile_s338_fragment('2026_rev_17',products)
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$products<-as.list(products);b$countries<-list('1220','2010');b$rules<-list();b$coverage<-list()
b$claim_definitions<-list();b$fact_definitions<-list();b$coverage_requirements<-list('base','section_232','section_338')
b$valid_from<-'2026-08-01T00:00:00-04:00';b$valid_until<-'2026-10-23T00:00:00-04:00'
b$dataset_version<-'synthetic-coverage-section338';b$revision<-'2026_rev_17'
sid<-'synthetic338-interactions';b$sources<-c(b$sources,list(list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/338-fixture',citation='Synthetic counterfactual action and coverage; not an authority attestation')))
make<-function(rule=NULL,coverage=TRUE) {
 bb<-b;bb$rules<-if(is.null(rule)) list() else list(rule)
 if(coverage) bb$coverage<-list(list(authority='section_232',status='verified',source_ids=list(sid),determination=if(is.null(rule)) 'no_applicable_rules' else 'rules',rule_ids=if(is.null(rule)) list() else list(rule$id)))
 compose_shipment_rules(bb,list(fragment))
}
mk<-function(id,code,amount=25) list(id=id,action_id=id,authority='section_232',kind='duty',verification='verified',source_ids=list(sid),reporting_codes=list(code),formula=list(value=amount),scope=list(),when=list(value=TRUE))
bundles<-list(none=make(),uncovered=make(coverage=FALSE),metal=make(mk('metal','9903.82.04')),zero=make(mk('zero','9903.82.02',0)),unknown=make(mk('unknown','9903.99.99',0)),vehicle=make(mk('vehicle','9903.94.02')),parts=make(mk('parts','9903.94.06',0)))
q<-list(customs_value=100,s338_personal_baggage=FALSE,s338_chapter98_claimed=FALSE,s338_ftz_entry=FALSE)
cases<-list()
add<-function(name,facts=q,subtotal=50,hts='2203000030',country='1220',at='2026-09-01T12:00:00-04:00',bundle='none',codes=NULL,missing=NULL,error=NULL) {
 r<-evaluate_shipment_bundle(bundles[[bundle]],hts,country,at,facts)
 if(abs(r$known_subtotal-subtotal)>1e-9) {print(r[c('known_subtotal','missing_inputs','source_errors')]);stop(name)}
 actual_codes<-sort(unique(unlist(lapply(Filter(function(c)c$status=='applied'&&c$authority=='section_338',r$components),`[[`,'reporting_codes'))))
 if(!is.null(codes)) stopifnot(setequal(actual_codes,codes))
 if(!is.null(missing)) stopifnot(setequal(r$missing_inputs,missing))
 if(!is.null(error)) stopifnot(any(grepl(error,r$source_errors,fixed=TRUE)))
 stopifnot(is.null(r$complete_total))
 cases[[length(cases)+1L]]<<-list(name=name,bundle=bundle,hts10=hts,country=country,entry_at=at,facts=facts,expected=list(known_subtotal=subtotal,missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors),codes=as.list(actual_codes)))
}
add('alcohol action statutory fifty',codes='9903.03.12',missing=character())
add('dairy separate action',hts='0402101000',codes='9903.03.13')
add('motor separate action',hts='8537109130',codes='9903.03.14')
add('wrong origin',country='2010',subtotal=0,codes=character(),missing=character())
add('original August19 date was suspended',at='2026-08-19T00:01:00-04:00',subtotal=0,codes=character())
add('one second before operative instant',at='2026-08-22T00:00:59-04:00',subtotal=0,codes=character())
add('at operative instant',at='2026-08-22T00:01:00-04:00')
add('metal action exempts whole article before September',bundle='metal',subtotal=25,codes='9903.03.15')
add('zero-dollar named metal decision still exempts',bundle='zero',subtotal=0,codes='9903.03.15')
add('unknown zero decision cannot prove absence',bundle='unknown',subtotal=0,error='unlisted_section232')
add('missing inventory cannot become fifty',bundle='uncovered',subtotal=0,error='coverage_dependency_unverified')
add('September first second stacks independent motor action',bundle='metal',subtotal=75,hts='8537109130',at='2026-09-15T00:01:00-04:00',codes='9903.03.14')
add('September preceding second keeps old interaction',bundle='metal',subtotal=25,hts='8537109130',at='2026-09-15T00:00:59-04:00',codes='9903.03.15')
add('September alcohol amount no longer needs 232 inventory',bundle='uncovered',at='2026-09-15T00:01:00-04:00',codes='9903.03.12')
add('September dairy exception remains',bundle='metal',hts='0402101000',subtotal=25,at='2026-09-15T00:01:00-04:00',codes='9903.03.15')
add('removed statistical suffix',hts='2208306085',subtotal=0,at='2026-09-15T00:01:00-04:00',codes=character(),missing=character())
add('retained adjacent suffix',hts='2208306075',at='2026-09-15T00:01:00-04:00',codes='9903.03.12')
add('narrowed machine subheading excludes removed suffix',hts='8537109120',subtotal=0,at='2026-09-15T00:01:00-04:00',codes=character())
f<-q;f$claims<-list('USMCA');add('USMCA does not remove 338',f,codes='9903.03.12')
f<-q;f$s338_personal_baggage<-TRUE;add('personal baggage',f,subtotal=0,codes=character())
f<-q;f$s338_civil_aircraft_gn6<-TRUE;add('source-listed civil-aircraft relief',f,hts='9403200090',subtotal=0,codes='9903.03.16')
f$s338_civil_aircraft_gn6<-FALSE;add('aircraft association alone insufficient',f,hts='9403200090',codes='9903.03.14')
f<-q;f$s338_ftz_entry<-TRUE;add('FTZ remains unresolved',f,subtotal=0,error='ftz_admission')
f<-q;f$s338_commerce_approved_us_vehicle_content<-TRUE;f$s338_vehicle_us_content_value<-40
add('qualified US vehicle content excludes only its value',f,bundle='vehicle',subtotal=55,codes=c('9903.03.12','9903.03.15'))
f<-q;f$s338_usmca_auto_parts_not_kits<-TRUE;add('qualifying USMCA parts relief',f,bundle='parts',subtotal=0,codes='9903.03.15')
f$s338_usmca_auto_parts_not_kits<-FALSE;add('kits not granted zero-duty parts relief',f,bundle='parts')
# Chapter 98 is a stack-wide claim, so uncompiled effects on other actions are
# deliberately unpriced. Synthetic empty 232 inventory isolates valuation.
f<-q;f$claims<-list('CHAPTER_98');f$s338_chapter98_claimed<-TRUE;f$chapter98_properly_claimed_and_cbp_agreed<-TRUE;f$chapter98_provision<-'98010010'
add('proper returned-good claim',f,subtotal=0,codes=character())
f$chapter98_provision<-'98230101';add('subchapter XXIII retains additional duty',f,codes='9903.03.12')
f$chapter98_provision<-'98020040';f$chapter98_repairs_alterations_processing_value<-30;f$s338_civil_aircraft_gn6<-FALSE
add('repairs valuation',f,subtotal=15,codes='9903.03.12')
f$chapter98_provision<-'98020050';add('alterations valuation',f,subtotal=15)
f$chapter98_provision<-'98020060';add('processing valuation',f,subtotal=15)
f$chapter98_provision<-'98020080';f$chapter98_us_products_value<-70;add('assembly value less qualifying US products',f,subtotal=15)
f$chapter98_us_products_value<-101;add('invalid assembly values never create negative duty',f,subtotal=0,missing=c('chapter98_us_products_value','customs_value'))
f$chapter98_us_products_value<-70;f$chapter98_properly_claimed_and_cbp_agreed<-FALSE;add('rejected Chapter98 claim does not waive duty',f)
f$chapter98_properly_claimed_and_cbp_agreed<-NULL;add('pending Chapter98 determination remains incomplete',f,subtotal=0,missing='chapter98_properly_claimed_and_cbp_agreed')
f<-q;f$modeled_share<-1;f$assembly_credit<-99999;add('model inputs cannot change statutory result',f)
# Independent 301 charge remains, and a source-bound 301 exclusion leaves 338 unchanged.
bb<-b;rr<-mk('301','9903.05.21',12.5);rr$authority<-'section_301';rr$when<-list(op='not',args=list(list(claim='fixture301')))
rr$exclusion_claim_id<-'fixture301'
bb$rules<-list(rr);bb$claim_definitions<-list(list(id='fixture301',label='Synthetic 301 relief',candidate_rule_ids=list('301'),rule_ids=list('301'),source_ids=list(sid)))
bb$coverage<-list(list(authority='section_232',status='verified',source_ids=list(sid),determination='no_applicable_rules',rule_ids=list()))
bundles$s301<-compose_shipment_rules(bb,list(fragment))
add('338 and 301 independent cumulative actions',bundle='s301',subtotal=62.5)
f<-q;f$claims<-list('fixture301');add('301 claim leaves 338 unchanged',f,bundle='s301')
bb<-b;rr<-mk('claimable232','9903.82.04');rr$when<-list(op='not',args=list(list(claim='fixture232')))
rr$grant_id<-'synthetic-grant';rr$grant_snapshot_id<-'synthetic-snapshot'
bb$rules<-list(rr);bb$coverage<-list(list(authority='section_232',status='verified',source_ids=list(sid),determination='rules',rule_ids=list(rr$id)))
bb$claim_definitions<-list(list(id='fixture232',label='Synthetic 232 grant',candidate_rule_ids=list(rr$id),rule_ids=list(rr$id),source_ids=list(sid)))
bundles$claim232<-compose_shipment_rules(bb,list(fragment))
add('unclaimed metal decision removes 338 before amendment',bundle='claim232',subtotal=25,codes='9903.03.15')
f<-q;f$claims<-list('fixture232');add('232 claim reevaluates and revives 338',f,bundle='claim232',codes='9903.03.12')
add('after amendment 338 remains despite 232 relief',f,bundle='claim232',at='2026-09-15T00:01:00-04:00',codes='9903.03.12')
shuffled<-fragment;shuffled$rules<-rev(shuffled$rules);shuffled$sources<-rev(shuffled$sources)
# Sources and rules deduplicate; compiler fragment audit labels intentionally
# retain the caller's fragment inventory, so compare executable projections.
dupe<-compose_shipment_rules(bb,list(shuffled,shuffled));single<-bundles$claim232
stopifnot(identical(.shipment_canonical(dupe$rules),.shipment_canonical(single$rules)),
 identical(.shipment_canonical(dupe$sources),.shipment_canonical(single$sources)))
if('--emit'%in%commandArgs(TRUE))jsonlite::write_json(list(bundles=bundles,cases=cases),'tests/fixtures/shipment/section338.json',auto_unbox=TRUE,null='null',digits=NA)
cat(length(cases),'Section 338 source-bound R/TypeScript fixture cases passed\n')
