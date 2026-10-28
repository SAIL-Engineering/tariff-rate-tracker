suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/section232_revision.R');source('src/compile_shipment_rules.R')
x<-load_s232_note16_source('2026_rev_19');fragment<-compile_s232_note16_fragment(x,'8427104090')
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$revision<-'2026_rev_19';b$dataset_version<-'note16-source-agreement-not-production';b$products<-list('8427104090');b$countries<-list('5700','5880','2010','4621')
b$valid_from<-fragment$supported_from;b$valid_until<-fragment$supported_until;b$rules<-b$coverage<-b$claim_definitions<-list();b$fact_definitions<-list();b$coverage_requirements<-list('base','section_232','adcvd')
base<-b;b<-compose_shipment_rules(b,list(fragment));prepared<-prepare_shipment_bundle(b);cases<-list()
q<-list(customs_value=100,ieepa_ftz_entry=FALSE,steel_weight_fraction=.5,us_steel_origin_fraction=.85,motorcycle_part_for_us_manufacture=FALSE)
add<-function(name,country='5700',facts=q,amount=10,code='9903.82.06',missing=character(),disagreement=FALSE,source_error=NULL) {
 r<-evaluate_shipment_prepared(prepared,'8427104090',country,'2026-09-15T12:00:00-04:00',facts)
 components<-Filter(function(c)c$authority=='section_232',r$components);applied<-Filter(function(c)c$status=='applied',components)
 actual<-unlist(lapply(applied,`[[`,'reporting_codes'))
 if(r$known_subtotal!=amount||!setequal(actual,code)||!setequal(r$missing_inputs,missing)) {
  print(list(case=name,known_subtotal=r$known_subtotal,codes=actual,missing=r$missing_inputs,errors=r$source_errors));stop('Equal original-source outcomes remain unnecessarily unresolved')
 }
 stopifnot(is.null(r$complete_total))
 errors<-unlist(lapply(components,`[[`,'source_errors'))
 if(!is.null(source_error))stopifnot(any(grepl(source_error,errors,fixed=TRUE)))
 else if(disagreement)stopifnot(any(grepl('note16_xi_us_metal_formula_conflict',errors,fixed=TRUE)))
 else stopifnot(!length(errors))
 cases[[length(cases)+1L]]<<-list(name=name,bundle='agreement',hts10='8427104090',country=country,entry_at='2026-09-15T12:00:00-04:00',facts=facts,expected=shipment_result_for_json(r))
}
add('Zero actual Column1: both original formulations owe ten dollars')
add('Zero Column1 partner: agreed US treatment is below partner rate',country='5880')
add('Russian heading retains its separate verified reporting identity',country='4621',code='9903.82.15')
f<-q;f$claims<-list('USMCA');f$usmca_origin_eligible<-TRUE
add('US metal agreed treatment takes precedence without asking an irrelevant content value',country='2010',facts=f)
f<-q;f$column1_duty_amount<-5
add('Caller benchmark cannot override a source-backed Free expression',facts=f)
f<-q;f$column1_duty_amount<-NULL
add('Source-backed Free closes the missing Column1 benchmark',facts=f)
f$us_steel_origin_fraction<-.84
add('Nonqualifying US material does not ask for an irrelevant Column1 value',facts=f,amount=25,code='9903.82.09')
f<-q;f$modeled_metal_share<-0;f$assembly_credit<-9999
add('Model shares cannot change agreement or reporting',facts=f)
f<-q;f$ieepa_ftz_entry<-NULL
add('Missing entry context cannot price a current-date metal amount',facts=f,amount=0,code=character(),missing='ieepa_ftz_entry')
f$ieepa_ftz_entry<-TRUE
add('FTZ history cannot borrow ordinary current-date liability',facts=f,amount=0,code=character(),source_error='note16_ftz_admission_status_classification_and_rate_history')
source('src/section301_labor.R')
overlap<-compose_shipment_rules(base,list(fragment,compile_s301_labor_fragment('2026_rev_19','8427104090')))
f<-q;f$customs_value<-NULL
r<-evaluate_shipment_bundle(overlap,'8427104090','5700','2026-09-15T12:00:00-04:00',f)
fl<-Filter(function(c)startsWith(c$action_id,'s301_forced_labor_')&&c$status=='applied',r$components)
if(length(fl)!=1L)stop('Investigations overlap or the expected single origin action is absent')
stopifnot(length(fl)==1L,fl[[1]]$amount==0,'9903.05.90'%in%unlist(fl[[1]]$reporting_codes),
 setequal(r$missing_inputs,'customs_value'),is.null(r$complete_total))
cases[[length(cases)+1L]]<-list(name='Established reporting applicability resolves another program without knowing the disputed metal amount',bundle='overlap',hts10='8427104090',country='5700',entry_at='2026-09-15T12:00:00-04:00',facts=f,expected=shipment_result_for_json(r))
bundles<-list(agreement=b,overlap=overlap)
# Before the statistical split, the valid canonical identity was .40.00.
# The June8 country treatment changes while that product identity stays valid.
for(spec in list(list(id='before_mobile',rev='2026_rev_8',at='2026-06-07T23:59:59-04:00',amount=25,code='9903.82.09'),
 list(id='after_mobile',rev='2026_rev_10',at='2026-06-08T00:01:00-04:00',amount=15,code='9903.82.22'))) {
 ff<-compile_s232_note16_fragment(load_s232_note16_source(spec$rev),'8427104000')
 bb<-base;bb$revision<-spec$rev;bb$products<-list('8427104000');bb$countries<-list('5880')
 bb$valid_from<-ff$supported_from;bb$valid_until<-ff$supported_until
 bb<-compose_shipment_rules(bb,list(ff));facts<-q;facts$us_steel_origin_fraction<-0
 r<-evaluate_shipment_bundle(bb,'8427104000','5880',spec$at,facts)
 metal<-Filter(function(c)c$authority=='section_232'&&c$status=='applied',r$components)
 stopifnot(sum(vapply(metal,`[[`,numeric(1),'amount'))==spec$amount,
  spec$code%in%unlist(lapply(metal,`[[`,'reporting_codes')),!length(r$missing_inputs),is.null(r$complete_total))
 bundles[[spec$id]]<-bb
 cases[[length(cases)+1L]]<-list(name=paste('Original June8 amendment and historical code validity:',spec$id),bundle=spec$id,
  hts10='8427104000',country='5880',entry_at=spec$at,facts=facts,expected=shipment_result_for_json(r))
}
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/note16-source-agreement.json.gz','w');writeLines(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'original-source agreement, native benchmark and missing-shipment-input cases passed\n')
