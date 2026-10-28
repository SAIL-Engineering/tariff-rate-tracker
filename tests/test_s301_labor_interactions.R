suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/section301_labor.R');source('src/compile_shipment_rules.R');source('src/legal_intervals.R')
source('tests/lib/bound_shipment_fixture.R')
fragment<-compile_s301_labor_fragment('2026_rev_13','7304313000')
fragments<-list('2026_rev_13'=fragment,'2026_rev_14'=compile_s301_labor_fragment('2026_rev_14','7304313000'))
fragments<-lapply(fragments,bound_shipment_fixture_countries,countries=c('4280','5330'))
history<-fragment$forced_labor_history
stopifnot(length(history$actions)==60L,length(history$original_headings)==101L)
stopifnot(setequal(as.character(legal_event_days(history)),c('2026-07-24','2026-07-28','2026-07-31','2026-10-23')))
base<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
base$revision<-'2026_rev_13';base$dataset_version<-'s301fl-controlled-interaction-not-production'
base$products<-list('7304313000');base$countries<-list('4280','5330');base$rules<-list();base$coverage<-list()
base$valid_from<-fragment$supported_from;base$valid_until<-fragment$supported_until;base$coverage_requirements<-list('base','section_301','section_232')
sid<-'controlled-s301fl-interaction'
base$sources<-list(list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/interaction',citation='Controlled Section232 decisions; not an applicability or full-total oracle'))
base$fact_definitions<-list();base$claim_definitions<-list();bundles<-list();cases<-list()
check<-function(code,at,amount=0,qualified=NULL,name=code,relief=TRUE,country='4280',active=TRUE,unresolved_count=1L,missing=character(),other_amount=0,ftz=FALSE,source_error=NULL) {
 b<-base
 rev<-if(substr(at,1,10)>='2026-07-31')'2026_rev_14' else '2026_rev_13'
 f<-fragments[[rev]];b$revision<-rev;b$valid_from<-f$supported_from;b$valid_until<-f$supported_until
 b$rules<-list(list(id='controlled-232',action_id='controlled-232',authority='section_232',kind='duty',verification='verified',source_ids=list(sid),
   reporting_codes=list(code),when=list(value=active),formula=list(value=amount)))
 if(other_amount>0)b$rules[[2]]<-list(id='independent-301',action_id='independent-301',authority='section_301',kind='duty',verification='verified',source_ids=list(sid),reporting_codes=list('9903.88.03'),formula=list(value=other_amount))
 b<-compose_shipment_rules(b,list(f));ordinary<-names(f$fact_definitions)[startsWith(names(f$fact_definitions),'s301_labor_')]
 facts<-setNames(rep(list(FALSE),length(ordinary)),ordinary);facts<-modifyList(facts,qualified %||% list());facts$modeled_aircraft_share<-0.90;facts$modeled_assembly_credit<-100000
 if(!is.null(ftz))facts$ieepa_ftz_entry<-ftz
 r<-evaluate_shipment_bundle(b,'7304313000',country,at,facts)
 components<-Filter(function(c)startsWith(c$action_id,'s301_forced_labor_'),r$components)
 applied<-Filter(function(c)c$status=='applied',components)
 unresolved<-Filter(function(c)c$status=='unresolved',components)
 if(relief)stopifnot(length(applied)==1L,applied[[1]]$amount==0,'9903.05.90'%in%unlist(applied[[1]]$reporting_codes),!length(unresolved))
 else stopifnot(!length(applied),length(unresolved)==unresolved_count,all(vapply(unresolved,function(c)is.null(c$amount),logical(1))))
 stopifnot(is.null(r$complete_total),r$known_subtotal==(if(active)amount else 0)+other_amount,setequal(r$missing_inputs,missing))
 if(other_amount>0)stopifnot('independent-301'%in%r$applied_rules)
 if(!is.null(source_error))stopifnot(any(grepl(source_error,r$source_errors,fixed=TRUE)))
 id<-paste0('b',length(bundles)+1L);bundles[[id]]<<-b
 cases[[length(cases)+1L]]<<-list(name=name,bundle=id,hts10='7304313000',country=country,entry_at=at,facts=facts,expected=shipment_result_for_json(r))
}
at<-'2026-07-24T12:00:00-04:00'
for(code in c('9903.82.02','9903.82.04','9903.82.20','9903.82.26','9903.94.01','9903.94.05','9903.94.69','9903.76.24','9903.74.03','9903.74.08','9903.79.01')) {
 check(code,at,name=paste(code,'zero payable remains subject to Section232'))
 check(code,at,amount=50,name=paste(code,'positive duty same applicability'))
 check(code,at,active=FALSE,relief=FALSE,name=paste(code,'inapplicable candidate does not exempt'))
}
for(code in c('9903.82.01','9903.82.03','9903.88.03'))check(code,at,relief=FALSE,name=paste(code,'not in source exemption'))
check('9903.94.02',at,qualified=list(s232_auto_approved_us_content=TRUE),name='Approved US vehicle content qualifies')
check('9903.94.02',at,qualified=list(s232_auto_approved_us_content=FALSE),relief=FALSE,name='Nonvehicle article sharing heading does not qualify')
check('9903.94.02',at,relief=FALSE,unresolved_count=2L,missing='s232_auto_approved_us_content',name='Unknown approved content cannot become a waiver or zero')
check('9903.94.06',at,qualified=list(s232_usmca_auto_parts_not_kits=TRUE),name='USMCA individual auto parts qualify')
check('9903.94.06',at,qualified=list(s232_usmca_auto_parts_not_kits=FALSE),relief=FALSE,name='Kits and other articles cannot borrow parts exception')
check('9903.74.10',at,qualified=list(s232_usmca_mhd_parts_not_kits=TRUE),name='MHD parts qualification retained')
check('9903.74.10',at,qualified=list(s232_usmca_mhd_parts_not_kits=FALSE),relief=FALSE,name='MHD other article does not qualify')
check('9903.04.60','2026-07-31T00:00:59-04:00',relief=FALSE,name='Pharma before original amendment minute')
check('9903.04.60','2026-07-31T00:01:00-04:00',name='Pharma at original amendment minute')
check('9903.04.66','2026-07-31T00:01:00-04:00',name='Pharma full original range')
check('9903.82.02',at,country='5330',name='Same Section232 decision applies to another investigated economy')
check('9903.82.02',at,other_amount=20,name='Forced-labor exemption does not remove an independent Section301 action')
check('9903.82.02',at,ftz=NULL,relief=FALSE,unresolved_count=2L,missing='ieepa_ftz_entry',name='Current reporting heading alone cannot establish ordinary versus FTZ history')
check('9903.82.02',at,ftz=TRUE,relief=FALSE,unresolved_count=2L,source_error='section301_forced_labor_ftz_admission_and_section232_reporting_history',name='FTZ admission and reporting history remains explicit')
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/section301-labor-interactions.json.gz','w')
 writeLines(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'source-named Section301/232 applicability and amendment cases passed\n')
