suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/section301_labor.R');source('src/shipment_build.R')
source('src/ieepa_reciprocal_revision.R')
revision<-'2026_rev_19';h<-load_s301_labor_history();native<-load_shipment_base_source(revision)
valid<-vapply(native$products,`[[`,character(1),'hts10')
matches<-function(p,codes) {codes<-unlist(codes);substr(p,1,8)%in%codes[nchar(codes)==8L]|p%in%codes[nchar(codes)==10L]}
candidates<-list();already_common<-0L
for(a in h$product_exemptions) {
 ps<-valid[matches(valid,a$includes)]
 ps<-ps[!matches(ps,h$common_products$includes)]
 if(!length(ps)) {already_common<-already_common+1L;next}
 action<-Filter(function(x)any(vapply(x$headings,function(r)r$reporting_code%in%unlist(a$target_reporting_codes),logical(1))),h$actions)[[1]]
 country<-as.character(unlist(resolve_original_action_origins(action$country_text)))[1]
 candidates[[length(candidates)+1L]]<-list(annex=a,hts10=ps[1],country=country)
}
products<-sort(unique(vapply(candidates,`[[`,character(1),'hts10')))
f<-compile_s301_labor_fragment(revision,products)
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$revision<-revision;b$dataset_version<-'s301-labor-complete-product-annexes-not-production';b$products<-as.list(products)
b$countries<-as.list(sort(unique(vapply(candidates,`[[`,character(1),'country'))))
b$rules<-b$coverage<-b$claim_definitions<-list();b$fact_definitions<-list();b$coverage_requirements<-list('base','section_301','adcvd')
b$valid_from<-f$supported_from;b$valid_until<-f$supported_until;b<-compose_shipment_rules(b,list(f));p<-prepare_shipment_bundle(b)
cases<-list();at<-'2026-09-15T12:00:00-04:00'
for(c in candidates) {
 a<-c$annex;facts<-setNames(lapply(names(f$fact_definitions),function(n)FALSE),names(f$fact_definitions));facts$ieepa_ftz_entry<-FALSE
 condition<-a$condition;key<-if(condition=='article_description')paste0('s301_labor_description_',substr(a$source_scope_sha256,1,16)) else paste0('s301_labor_',condition)
 if(condition!='none')facts[[key]]<-TRUE
 if(condition=='cafta_dr_claim_gn29')facts$claims<-list('CAFTA_DR')
 r<-evaluate_shipment_prepared(p,c$hts10,c$country,at,facts)
 applied<-Filter(function(c)c$status=='applied',r$components)
 if(!a$reporting_code%in%unlist(lapply(applied,`[[`,'reporting_codes'))) {
  print(list(annex=a$reporting_code,product=c$hts10,origin=c$country,result=r));stop('An original annex decision was not executable')
 }
 stopifnot(r$known_subtotal==0,is.null(r$complete_total))
 cases[[length(cases)+1L]]<-list(name=paste(a$reporting_code,a$item %||% condition,c$hts10,c$country),hts10=c$hts10,country=c$country,entry_at=at,facts=facts,expected=shipment_result_for_json(r))
 if(condition!='none') {
  facts[[key]]<-FALSE;r<-evaluate_shipment_prepared(p,c$hts10,c$country,at,facts)
  stopifnot(!a$reporting_code%in%unlist(lapply(Filter(function(c)c$status=='applied',r$components),`[[`,'reporting_codes')))
  cases[[length(cases)+1L]]<-list(name=paste(a$reporting_code,a$item %||% condition,'condition false'),hts10=c$hts10,country=c$country,entry_at=at,facts=facts,expected=shipment_result_for_json(r))
 }
}
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/section301-labor-annexes.json.gz','w');writeLines(jsonlite::toJSON(list(bundle=b,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'source-selected annex qualification and false-condition cases passed;',already_common,'scope rows already covered by the unconditional common table\n')
