suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/ieepa_reciprocal_revision.R');source('src/compile_shipment_rules.R')
rev<-'2025_rev_24';products<-'0106199120'
f<-compile_reciprocal_initial_fragment(load_reciprocal_scope(rev),products)
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$revision<-rev;b$dataset_version<-'transit-boundary-not-production';b$products<-list(products);b$countries<-list('5330')
s<-list(id='synthetic-transit-232-inventory',status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/transit-fixture',citation='Synthetic no232 inventory only; not a legal all-authority attestation')
b$sources<-list(s);b$rules<-list();b$claim_definitions<-list();b$fact_definitions<-list();b$coverage_requirements<-list('base','section_232','ieepa_reciprocal')
b$coverage<-list(list(authority='section_232',status='verified',source_ids=list(s$id),rule_ids=list(),determination='no_applicable_rules'))
b$valid_from<-f$supported_from;b$valid_until<-f$supported_until;b<-compose_shipment_rules(b,list(f));p<-prepare_shipment_bundle(b)
q<-list(customs_value=100,ieepa_ftz_entry=FALSE,ieepa_personal_accompanied_baggage=FALSE,
 ieepa_qualifying_humanitarian_donation=FALSE,ieepa_informational_material=FALSE,ieepa_de_minimis_claimed=FALSE,
 reciprocal_cbp_transshipment_evasion_determination=FALSE,claims=list('RECIPROCAL_TRANSIT'),reciprocal_transit_final_vessel=TRUE,
 reciprocal_august_transit_loaded_before_cutoff=TRUE)
cases<-list()
for(at in c('2025-10-05T00:00:59-04:00','2025-10-05T00:01:00-04:00')) {
 r<-evaluate_shipment_prepared(p,products,'5330',at,q);expected<-if(at=='2025-10-05T00:00:59-04:00')10 else 25
 print(list(entry_at=at,expected=expected,known_subtotal=r$known_subtotal))
 stopifnot(r$known_subtotal==expected,is.null(r$complete_total))
 cases[[length(cases)+1L]]<-list(name=paste('Transit entry cutoff',at),bundle=rev,hts10=products,country='5330',entry_at=at,facts=q,
  expected=list(known_subtotal=expected,codes=as.list(sort(unique(unlist(lapply(Filter(function(x)x$status=='applied',r$components),`[[`,'reporting_codes'))))),missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors)))
}
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/ieepa-reciprocal-transit-boundary.json.gz','w');writeLines(jsonlite::toJSON(list(bundles=setNames(list(b),rev),cases=cases),auto_unbox=TRUE,null='null',digits=NA),out);close(out)
}
cat('Reciprocal transit deadline ends within an HTS source interval\n')
