suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/section301_labor.R');source('src/compile_shipment_rules.R')
# These real source pairs catch either dropping a ten-digit entry or broadening
# it to every child of the eight-digit provision. Production has no examples.
products<-c('0712908550','0712908580','1204000010','1204000035','8505110070','8505110090','0201100510','0201100590')
fragment<-compile_s301_labor_fragment('2026_rev_13',products)
base<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
base$revision<-'2026_rev_13';base$dataset_version<-'s301fl-common-products-not-production';base$products<-as.list(products);base$countries<-list('4280','5330','5880')
base$valid_from<-fragment$supported_from;base$valid_until<-fragment$supported_until;base$rules<-base$coverage<-base$claim_definitions<-list();base$fact_definitions<-list();base$coverage_requirements<-list('base','section_232','section_301','adcvd')
bundle<-compose_shipment_rules(base,list(fragment));prepared<-prepare_shipment_bundle(bundle);cases<-list()
check<-function(name,hts,exempt=TRUE,country='4280',at='2026-07-24T12:00:00-04:00',ftz=FALSE,before=FALSE) {
 facts<-structure(list(),names=character());if(!is.null(ftz))facts$ieepa_ftz_entry<-ftz
 r<-evaluate_shipment_prepared(prepared,hts,country,at,facts)
 fl<-Filter(function(c)startsWith(c$action_id,'s301_forced_labor_'),r$components);applied<-Filter(function(c)c$status=='applied',fl)
 if(before)stopifnot(!length(fl))
 else if(exempt) {
  if(length(applied)!=1L||!('9903.05.86'%in%unlist(applied[[1]]$reporting_codes))) {
   print(list(case=name,components=fl));stop('Original exact common-product exemption remains unpriced or is misattributed')
  }
  stopifnot(applied[[1]]$amount==0,!length(unlist(lapply(fl,`[[`,'missing_inputs'))),!length(unlist(lapply(fl,`[[`,'source_errors'))))
 } else {
  stopifnot(!length(applied),any(vapply(fl,function(c)c$status=='unresolved',logical(1))))
  if(is.null(ftz))stopifnot('ieepa_ftz_entry'%in%r$missing_inputs)
 }
 stopifnot(r$known_subtotal==0,is.null(r$complete_total))
 cases[[length(cases)+1L]]<<-list(name=name,bundle='common',hts10=hts,country=country,entry_at=at,facts=facts,expected=shipment_result_for_json(r))
}
check('Exact sweet-corn seed exemption','0712908550')
check('Adjacent dried-vegetable child cannot borrow exemption','0712908580',exempt=FALSE)
check('Exact flaxseed for sowing','1204000010')
check('Other flaxseed cannot borrow sowing exemption','1204000035',exempt=FALSE)
check('Exact sintered neodymium magnet','8505110070')
check('Adjacent other magnet cannot borrow exemption','8505110090',exempt=FALSE)
check('Eight-digit product scope includes first valid child','0201100510')
check('Eight-digit product scope includes adjacent valid child','0201100590')
check('Same exact exemption for another investigated economy','0712908550',country='5330')
check('Exemption precedes the Japanese cap calculation','0712908550',country='5880')
check('Before legal first minute no forced-labor action','0712908550',at='2026-07-24T00:00:59-04:00',before=TRUE)
check('At legal first minute exact exemption applies','0712908550',at='2026-07-24T00:01:00-04:00')
check('Unknown FTZ history cannot become ordinary product relief','0712908550',exempt=FALSE,ftz=NULL)
check('FTZ classification history remains required','0712908550',exempt=FALSE,ftz=TRUE)
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/section301-labor-common.json.gz','w');writeLines(jsonlite::toJSON(list(bundles=list(common=bundle),cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'exact common-product and historical-boundary cases passed\n')
