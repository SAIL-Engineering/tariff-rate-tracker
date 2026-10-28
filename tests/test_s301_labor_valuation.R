suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/section301_labor.R');source('src/shipment_build.R')
source('tests/lib/bound_shipment_fixture.R')
products<-c('6912004810','8211912000');bundles<-list();prepared<-list()
for(revision in c('2026_rev_13','2026_rev_19')) {
 f<-compile_s301_labor_fragment(revision,products)
 f<-bound_shipment_fixture_countries(f,c('5700','1220','5880','5800','4419','4280','5830'))
 b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
 b$revision<-revision;b$dataset_version<-'original-note52-valuation-not-production';b$products<-as.list(products);b$countries<-list('5700','1220','5880','5800','4419','4280','5830')
 b$rules<-b$coverage<-b$claim_definitions<-list();b$fact_definitions<-list();b$coverage_requirements<-list('base','section_301','section_232','adcvd')
 b$valid_from<-f$supported_from;b$valid_until<-f$supported_until
 sid<-'controlled-232-absence-for-valuation-only'
 b$sources<-list(list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/valuation-fixture',citation='Controlled absence tests the source-derived forced-labor calculation only; not a Section232 legal oracle or all-authority total.'))
 b$coverage<-list(list(authority='section_232',status='verified',determination='no_applicable_rules',rule_ids=list(),source_ids=list(sid)))
 bundles[[revision]]<-compose_shipment_rules(b,list(f));prepared[[revision]]<-prepare_shipment_bundle(bundles[[revision]])
}
q<-list(customs_value=100,ieepa_ftz_entry=FALSE)
for(n in names(f$fact_definitions)[startsWith(names(f$fact_definitions),'s301_labor_')])q[[n]]<-FALSE
cases<-list()
check<-function(name,facts=q,country='5700',amount=12.5,code='9903.05.31',at='2026-09-15T12:00:00-04:00',missing=character(),hts='6912004810') {
 revision<-if(substr(at,1,7)=='2026-07')'2026_rev_13' else '2026_rev_19'
 r<-evaluate_shipment_prepared(prepared[[revision]],hts,country,at,facts)
 fl<-Filter(function(c)startsWith(c$action_id,'s301_forced_labor_'),r$components)
 applied<-Filter(function(c)c$status=='applied',fl)
 stopifnot(abs(r$known_subtotal-amount)<1e-9,is.null(r$complete_total),setequal(r$missing_inputs,missing))
 if(!length(missing)) {
  stopifnot(length(applied)==1L,applied[[1]]$amount==amount,!length(unlist(lapply(fl,`[[`,'source_errors'))))
  if(!is.null(code))stopifnot(code%in%unlist(applied[[1]]$reporting_codes))
 }
 cases[[length(cases)+1L]]<<-list(name=name,bundle=revision,hts10=hts,country=country,entry_at=at,facts=facts,expected=shipment_result_for_json(r))
}
check('Ordinary China action uses its published additional rate')
check('Unclaimed Canadian entry does not inherit modeled USMCA relief',country='1220',amount=10,code='9903.05.29')
u<-q;u$claims<-list('USMCA');u$s301_labor_usmca_entered_free<-TRUE
check('Actually entered free under USMCA removes the Canadian action',u,'1220',0,'9903.05.93')
u$s301_labor_usmca_entered_free<-FALSE
check('A preference request without actual duty-free entry leaves the action',u,'1220',10,'9903.05.29')
c<-q;c$claims<-list('CHAPTER_98');c$chapter98_properly_claimed_and_cbp_agreed<-TRUE;c$chapter98_provision<-'98020040';c$chapter98_repairs_alterations_processing_value<-20
check('Source repair exception uses actual processing value',c,amount=2.5)
c$chapter98_provision<-'98020080';c$chapter98_us_products_value<-60
check('Source assembly exception uses actual non-US value',c,amount=5)
c$chapter98_provision<-'98010010'
check('Properly claimed CBP-agreed Chapter98 exemption removes the action',c,amount=0,code=NULL)
c$chapter98_properly_claimed_and_cbp_agreed<-NULL
check('An unestablished Chapter98 claim cannot become a zero',c,amount=0,code=NULL,missing='chapter98_properly_claimed_and_cbp_agreed')
z<-q;z$s301_labor_loaded_and_final_transit_before_start<-TRUE
check('Original final-mode transit exemption during its window',z,amount=0,code='9903.05.85',at='2026-07-24T00:01:00-04:00')
check('Transit entry deadline is exclusive',z,at='2026-07-28T00:01:00-04:00')
z<-q;z$s301_labor_informational_material<-TRUE;z$customs_value<-NULL
check('A proven informational-material exemption does not request a value',z,amount=0,code='9903.05.92')
check('Unclaimed Korean floor uses the published General benchmark',country='5800',amount=2.7,code='9903.05.71')
check('Japanese floor uses the published General benchmark',country='5880',amount=2.7,code='9903.05.49')
check('Swiss floor uses the published General benchmark',country='4419',amount=2.7,code='9903.05.74')
check('EU floor comes from its own original threshold',country='4280',amount=.2,code='9903.05.39')
check('Taiwan floor comes from its own original threshold',country='5830',amount=.2,code='9903.05.76')
k<-q;k$claims<-list('COLUMN1_SPECIAL');k$column1_special_program<-'KR';k$column1_special_properly_claimed_and_eligible<-TRUE
check('Properly claimed native KR Free has its own Korean floor',k,'5800',12.5,'9903.05.71')
k<-q;k$quantity_each<-10
check('Compound General floor uses the actual legal quantity',k,'5880',6.06,'9903.05.49',hts='8211912000')
k$quantity_each<-2000
check('Compound AVE at or above the cap uses the source no-addition heading',k,'5880',0,'9903.05.48',hts='8211912000')
k$quantity_each<-NULL
check('Unpriced legal quantity cannot become an averaged or zero benchmark',k,'5880',0,NULL,missing='quantity_each',hts='8211912000')
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/section301-labor-valuation.json.gz','w');writeLines(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'original forced-labor rate, preference, Chapter98 and transit calculations passed; no full-stack attestation\n')
