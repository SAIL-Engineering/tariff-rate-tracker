suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/ieepa_reciprocal_revision.R');source('src/compile_shipment_rules.R')
# Product scope is real. This fixture establishes a controlled metal charge to
# test its removal, not an assertion that this product actually owes that charge.
rev<-'2025_rev_21';product<-'8471500150'
f<-compile_reciprocal_initial_fragment(load_reciprocal_scope(rev),product)
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$revision<-rev;b$dataset_version<-'overlapping-exemptions-not-production';b$products<-list(product);b$countries<-list('4280','4120')
s<-list(id='synthetic-overlap-metal-inventory',status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/overlap',citation='Controlled metal action, not real product applicability')
b$sources<-list(s);b$claim_definitions<-list();b$fact_definitions<-list();b$coverage_requirements<-list('base','section_232','ieepa_reciprocal')
b$rules<-lapply(c('4280','4120'),function(country)list(id=paste0('controlled-metal-',country),action_id='controlled-metal',authority='section_232',kind='duty',verification='verified',
 source_ids=list(s$id),scope=list(hts_exact=list(product),countries=list(country)),reporting_codes=list(if(country=='4280')'9903.81.87' else '9903.81.94'),when=list(value=TRUE),formula=list(value=50)))
b$coverage<-list(list(authority='section_232',status='verified',source_ids=list(s$id),rule_ids=as.list(vapply(b$rules,`[[`,character(1),'id')),determination='rules'))
b$valid_from<-f$supported_from;b$valid_until<-f$supported_until;b<-compose_shipment_rules(b,list(f));p<-prepare_shipment_bundle(b)
q<-list(customs_value=100,ieepa_ftz_entry=FALSE,ieepa_personal_accompanied_baggage=FALSE,
 ieepa_qualifying_humanitarian_donation=FALSE,ieepa_informational_material=FALSE,ieepa_de_minimis_claimed=FALSE,
 reciprocal_cbp_transshipment_evasion_determination=FALSE)
cases<-list()
for(country in c('4280','4120'))for(eligible in list(TRUE,FALSE,NULL)) {
 key<-if(country=='4280')'reciprocal_partner_civil_aircraft_gn6_excluding_unmanned' else 'uk_civil_aircraft_gn6'
 facts<-q;facts[[key]]<-eligible
 r<-evaluate_shipment_prepared(p,product,country,'2025-09-02T12:00:00-04:00',facts)
 codes<-sort(unique(unlist(lapply(Filter(function(c)c$authority=='ieepa_reciprocal'&&c$status=='applied',r$components),`[[`,'reporting_codes'))))
 expected<-if(is.null(eligible))0 else if(eligible)0 else 50
 wanted<-if(is.null(eligible))character() else if(eligible)if(country=='4280')'9903.02.76' else '9903.96.01' else '9903.01.32'
 print(list(eligible=eligible,known_subtotal=r$known_subtotal,codes=codes))
 stopifnot(r$known_subtotal==expected,setequal(codes,wanted),is.null(r$complete_total),
  if(is.null(eligible))identical(r$missing_inputs,key) else !length(r$missing_inputs))
 cases[[length(cases)+1L]]<-list(name=paste('Overlapping AnnexII and partner relief',country,eligible %||% 'unknown'),bundle=rev,
  hts10=product,country=country,entry_at='2025-09-02T12:00:00-04:00',facts=facts,
  expected=list(known_subtotal=expected,codes=as.list(codes),missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors)))
}
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/ieepa-reciprocal-overlap.json.gz','w');writeLines(jsonlite::toJSON(list(bundles=setNames(list(b),rev),cases=cases),auto_unbox=TRUE,null='null',digits=NA),out);close(out)
}
cat('Six overlapping AnnexII / EU and UK aircraft / metal decisions passed\n')
