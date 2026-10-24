suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/ieepa_fentanyl.R');source('src/ieepa_actions.R');source('src/section232_legacy.R');source('src/compile_shipment_rules.R')
products<-c('7318158085','8703230190')
sid<-'synthetic-emergency-interactions'
source_fixture<-list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/emergency-fixture',citation='Synthetic Section 232 inventory for dependency tests, not complete legal coverage')
make<-function(rev,metal=FALSE,extra=NULL,coverage=TRUE) {
 x<-load_ieepa_emergency_source(rev);fragment<-compile_ieepa_emergency_fragment(x,products)
 b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
 b$revision<-rev;b$dataset_version<-'emergency-regression-not-production';b$rules<-if(is.null(extra)) list() else list(extra)
 b$products<-as.list(products);b$countries<-list('1220','2010','5700','5820');b$coverage<-list()
 b$fact_definitions<-list();b$claim_definitions<-list();b$sources<-c(b$sources,list(source_fixture))
 b$coverage_requirements<-list('base','section_232','ieepa_fentanyl');b$valid_from<-fragment$supported_from;b$valid_until<-fragment$supported_until
 # Exercise the same separately emitted source inventory as release composition.
 extracted<-structure(list(),emergency_source=x)
 evidence<-attach_emergency_evidence(ieepa_evidence_fragment(NULL,rev),extracted)
 fs<-list(evidence,fragment)
 if(metal)fs<-c(fs,list(compile_s232_legacy_fragment(load_s232_legacy_source(rev),products)))
 b<-compose_shipment_rules(b,fs)
 if(coverage) {
  ids<-vapply(Filter(function(r)r$authority=='section_232',b$rules),`[[`,character(1),'id')
  b$coverage<-list(list(authority='section_232',status='verified',source_ids=list(sid),determination=if(length(ids)) 'rules' else 'no_applicable_rules',rule_ids=as.list(ids)))
 }
 b
}
mk<-function(code,amount=0)list(id='synthetic-232',action_id='synthetic-232',authority='section_232',kind='duty',verification='verified',source_ids=list(sid),scope=list(),reporting_codes=list(code),when=list(value=TRUE),formula=list(value=amount))
bundles<-list(first=make('2025_rev_1'),march=make('2025_rev_4'),may=make('2025_rev_13',TRUE),june=make('2025_rev_14',TRUE),august=make('2025_rev_17'),november=make('2025_rev_28'),missing=make('2025_rev_28',coverage=FALSE),
 zero_auto=make('2025_rev_26',TRUE,mk('9903.94.06')),zero_deal=make('2025_rev_26',TRUE,mk('9903.94.42')),wood=make('2025_rev_26',extra=mk('9903.76.01',25)))
q<-list(customs_value=100,ieepa_origin_rule_confirmed=TRUE,ieepa_personal_accompanied_baggage=FALSE,
 ieepa_qualifying_humanitarian_donation=FALSE,ieepa_informational_material=FALSE,ieepa_ftz_entry=FALSE,
 ieepa_de_minimis_claimed=FALSE,ieepa_potash=FALSE,ieepa_canada_energy_or_critical_mineral=FALSE,
 ieepa_canada_cbp_evasion_determination=FALSE,ieepa_china_transit_loading_satisfied=FALSE)
steel<-list(steel_content_value=20,contains_steel=TRUE,steel_processed_from_us_metal=FALSE,
 privileged_ftz_before_20250604=FALSE,privileged_ftz_before_20250312=FALSE)
cases<-list()
add<-function(name,bundle='november',facts=q,country='5700',at=NULL,subtotal=10,codes=NULL,error=NULL,missing=NULL) {
 if(is.null(at))at<-switch(bundle,first='2025-02-04T12:00:00-05:00',march='2025-03-08T12:00:00-05:00',may='2025-05-20T12:00:00-04:00',june='2025-06-05T12:00:00-04:00',august='2025-08-02T12:00:00-04:00',zero_auto='2025-11-02T12:00:00-05:00',zero_deal='2025-11-02T12:00:00-05:00',wood='2025-11-02T12:00:00-05:00','2025-11-11T12:00:00-05:00')
 r<-evaluate_shipment_bundle(bundles[[bundle]],products[1],country,at,facts)
 actual<-sort(unique(unlist(lapply(Filter(function(x)x$authority=='ieepa_fentanyl'&&x$status=='applied',r$components),`[[`,'reporting_codes'))))
 if(abs(r$known_subtotal-subtotal)>1e-9||(!is.null(codes)&&!setequal(codes,actual))||(!is.null(error)&&!any(grepl(error,r$source_errors,fixed=TRUE)))||(!is.null(missing)&&!setequal(missing,r$missing_inputs))) {
  print(list(case=name,expected=subtotal,codes=actual,result=r[c('known_subtotal','missing_inputs','source_errors')]));stop('Emergency decision regression')
 }
 stopifnot(is.null(r$complete_total))
 cases[[length(cases)+1L]]<<-list(name=name,bundle=bundle,hts10=products[1],country=country,entry_at=at,facts=facts,expected=list(known_subtotal=subtotal,codes=as.list(actual),missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors)))
}
add('China original ten percent',bundle='first',codes='9903.01.20')
add('inception one second early',bundle='first',at='2025-02-04T00:00:59-05:00',subtotal=0,codes=character())
add('inception exact instant',bundle='first',at='2025-02-04T00:01:00-05:00')
f<-q;f$ieepa_china_transit_loading_satisfied<-TRUE
add('loaded before cutoff within entry window',bundle='first',facts=f,subtotal=0,codes='9903.01.23')
add('transit entry window ends even with qualifying loading',bundle='march',facts=f,subtotal=20,codes='9903.01.24')
add('transit before last entry minute',bundle='march',facts=f,at='2025-03-07T00:00:59-05:00',subtotal=0,codes='9903.01.23')
add('Hong Kong follows named origin action',country='5820')
add('November immediately before replacement',at='2025-11-10T00:00:59-05:00',subtotal=20)
add('November exact replacement instant',at='2025-11-10T00:01:00-05:00')
add('Canada ordinary August not conditional forty',bundle='august',country='1220',subtotal=35,codes='9903.01.10')
add('Canada before August rate minute',bundle='august',country='1220',at='2025-08-01T00:00:59-04:00',subtotal=25)
f<-q;f$ieepa_canada_energy_or_critical_mineral<-TRUE
add('Canadian energy separate rate',bundle='august',facts=f,country='1220',codes='9903.01.13')
f<-q;f$ieepa_potash<-TRUE
add('Mexican potash separate rate',bundle='march',facts=f,country='2010',codes='9903.01.05')
add('potash first minute still ordinary',bundle='march',facts=f,country='2010',at='2025-03-07T00:00:59-05:00',subtotal=25,codes='9903.01.01')
f<-q;f$ieepa_canada_cbp_evasion_determination<-TRUE;f$ieepa_canada_usmca_originating<-FALSE
add('CBP evasion replaces rather than adds',bundle='august',facts=f,country='1220',subtotal=40,codes='9903.01.16')
f$ieepa_potash<-TRUE;add('evasion replaces potash too',bundle='august',facts=f,country='1220',subtotal=40,codes='9903.01.16')
f$ieepa_canada_usmca_originating<-TRUE;add('originating but unclaimed does not trigger evasion replacement',bundle='august',facts=f,country='1220',subtotal=10,codes='9903.01.15')
f<-q;f$claims<-list('USMCA');f$ieepa_usmca_entered_free<-TRUE
add('claimed GN11 relief',bundle='march',facts=f,country='2010',subtotal=0,codes='9903.01.04')
f$ieepa_usmca_entered_free<-NULL;add('claim without qualification stays incomplete',bundle='march',facts=f,country='2010',subtotal=0,missing='ieepa_usmca_entered_free')
f<-q;f$ieepa_ftz_entry<-TRUE;add('FTZ does not inherit entry-date rate',facts=f,subtotal=0,error='ftz_admission')
f$claims<-list('USMCA');f$ieepa_usmca_entered_free<-TRUE
add('USMCA cannot bypass unresolved FTZ admission history',facts=f,country='2010',subtotal=0,error='ftz_admission')
f$claims<-list('CHAPTER_98');f$chapter98_provision<-'98010010';f$chapter98_properly_claimed_and_cbp_agreed<-TRUE
add('Chapter 98 cannot bypass unresolved FTZ admission history',facts=f,subtotal=0,error='ftz_admission')
f<-q;f$ieepa_ftz_entry<-TRUE;f$ieepa_informational_material<-TRUE
add('ordinary exemption requires FTZ historical decision first',facts=f,subtotal=0,error='ftz_admission')
f<-q;f$ieepa_de_minimis_claimed<-TRUE;add('de minimis requires its chronology',facts=f,subtotal=0,error='de_minimis')
add('missing 232 inventory cannot create a known duty',bundle='missing',subtotal=0,error='coverage_dependency_unverified')
f<-q;f$ieepa_qualifying_humanitarian_donation<-TRUE
add('donation reports its own heading without valuation facts',facts=f,subtotal=0,codes='9903.01.21')
f<-q;f$ieepa_informational_material<-TRUE;add('informational materials reporting',facts=f,subtotal=0,codes='9903.01.22')
f<-q;f$claims<-list('CHAPTER_98');f$chapter98_properly_claimed_and_cbp_agreed<-TRUE;f$chapter98_provision<-'98010010'
add('proper returned-goods claim',facts=f,subtotal=0,codes=character())
f$chapter98_provision<-'98020040';f$chapter98_repairs_alterations_processing_value<-30;f$ieepa_chapter98_operations_in_covered_origin<-TRUE
add('repair valuation in covered origin',facts=f,subtotal=3)
f$chapter98_provision<-'98020050';add('alteration valuation',facts=f,subtotal=3)
f$chapter98_provision<-'98020060';add('processing valuation',facts=f,subtotal=3)
f$chapter98_provision<-'98020080';f$chapter98_us_products_value<-70;add('assembly excludes US products',facts=f,subtotal=3)
f$ieepa_chapter98_operations_in_covered_origin<-FALSE;add('other processing origin requires reconciliation',facts=f,subtotal=0,error='other_processing_origins')
f$ieepa_chapter98_operations_in_covered_origin<-TRUE;f$chapter98_us_products_value<-101;add('assembly cannot have negative base',facts=f,subtotal=0,missing=c('chapter98_us_products_value','customs_value'))
f<-c(q,steel);add('May emergency suppresses metal',bundle='may',facts=f,country='2010',subtotal=25,codes='9903.01.01')
f$claims<-list('USMCA');f$ieepa_usmca_entered_free<-TRUE
add('May USMCA claim revives metal',bundle='may',facts=f,country='2010',subtotal=25,codes='9903.01.04')
f<-c(q,steel);add('June metal suppresses emergency',bundle='june',facts=f,country='2010',subtotal=10,codes=character())
f$steel_processed_from_us_metal<-TRUE;add('zero metal relief restores emergency',bundle='june',facts=f,country='2010',subtotal=25,codes='9903.01.01')
f<-c(q,steel);f$s232_usmca_auto_parts_not_kits<-TRUE
add('post-November qualifying zero auto decision suppresses metal and emergency',bundle='zero_auto',facts=f,country='2010',subtotal=0,codes=character())
add('one second before vehicle amendment keeps positive-payable test',bundle='zero_auto',facts=f,country='2010',at='2025-11-01T00:00:59-04:00',subtotal=10,codes=character())
f$s232_usmca_auto_parts_not_kits<-FALSE;add('same zero heading non-auto part does not suppress metal',bundle='zero_auto',facts=f,country='2010',subtotal=10,codes=character())
f$s232_usmca_auto_parts_not_kits<-NULL;add('mixed reporting heading requires actual use',bundle='zero_auto',facts=f,country='2010',subtotal=0,missing='s232_usmca_auto_parts_not_kits')
f<-c(q,steel);add('zero country deal decision retains subject-to status',bundle='zero_deal',facts=f,country='2010',subtotal=0,codes=character())
add('wood decision suppresses Canadian emergency',bundle='wood',country='1220',subtotal=25,codes=character())
f<-q;f$ieepa_potash<-TRUE;add('wood precedence includes the potash action, not only ordinary heading',bundle='wood',facts=f,country='2010',subtotal=25,codes=character())
f<-q;f$ieepa_canada_cbp_evasion_determination<-TRUE;f$ieepa_canada_usmca_originating<-FALSE
add('wood exception expressly includes Canadian evasion action',bundle='wood',facts=f,country='1220',subtotal=25,codes=character())
f<-q;f$ieepa_origin_rule_confirmed<-FALSE;add('conflicting legal origin is not an exemption',facts=f,country='2010',subtotal=0,error='unestablished_origin')
f<-q;f$modeled_share<-0;f$assembly_credit<-100000;add('aggregate inputs cannot change shipment',facts=f)
if('--emit'%in%commandArgs(TRUE))jsonlite::write_json(list(bundles=bundles,cases=cases),'tests/fixtures/shipment/ieepa-emergency.json',auto_unbox=TRUE,null='null',digits=NA)
cat(length(cases),'source-bound IEEPA emergency and cross-program decisions passed\n')
