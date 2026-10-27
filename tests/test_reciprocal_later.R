suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/ieepa_reciprocal_revision.R');source('src/compile_shipment_rules.R')
# Published product examples are regression fixtures only. No source rule is
# defined from these examples, and the Section232 attestation is synthetic.
products<-c('0106199120','4009120020','8471500150','8473301180','3301295118')
sid<-'synthetic-later-reciprocal-inventory'
synthetic<-list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/later-reciprocal',citation='Synthetic complete232 inventory, for cross-program arithmetic only')
fragments<-list();bundles<-list();prepared<-list();cases<-list();direct_checked<-character()
make<-function(rev,extra=list(),other_fragments=list()) {
 if(is.null(fragments[[rev]]))fragments[[rev]]<<-compile_reciprocal_initial_fragment(load_reciprocal_scope(rev),products)
 f<-fragments[[rev]]
 b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
 b$revision<-rev;b$dataset_version<-'later-reciprocal-regression-not-production';b$products<-as.list(products)
 b$countries<-as.list(c('1220','2010','5700','4280','5880','5800','4419','4411','4120'))
 b$rules<-extra;b$sources<-list(synthetic);b$fact_definitions<-list();b$claim_definitions<-list()
 b$coverage_requirements<-list('base','section_232','ieepa_reciprocal');b$coverage<-list()
 b$valid_from<-f$supported_from;b$valid_until<-f$supported_until
 # Bind reporting predicates after every participating action is present, as
 # assemble_shipment_state does. A compiled bundle is not an input fragment.
 b<-compose_shipment_rules(b,c(list(f),other_fragments))
 b$coverage<-c(b$coverage,list(list(authority='section_232',status='verified',source_ids=list(sid),rule_ids=as.list(vapply(extra,`[[`,character(1),'id')),determination=if(length(extra))'rules' else 'no_applicable_rules')))
 b
}
for(r in c('2025_rev_18','2025_rev_20','2025_rev_21','2025_rev_23','2025_rev_26','2025_rev_28','2025_rev_29','2026_rev_1','2026_rev_3','2026_rev_4','2026_rev_19')) {
 cat('Compiling later-policy regression:',r,'\n');flush.console()
 bundles[[r]]<-make(r)
}
mk<-function(code,amount=0)list(id=paste0('synthetic-',gsub('\\.','-',code)),action_id='synthetic-established-sector-decision',authority='section_232',
 kind='duty',verification='verified',source_ids=list(sid),scope=list(hts_exact=list(products[2])),reporting_codes=list(code),when=list(value=TRUE),formula=list(value=amount))
# These controlled interactions assume a named232 decision has already been
# established. They do not assert MHDV/wood scope for the hose example.
bundles$timber<-make('2025_rev_26',list(mk('9903.76.01',10)))
bundles$outside_timber<-make('2025_rev_26',list(mk('9903.76.04')))
bundles$mh_zero<-make('2025_rev_26',list(mk('9903.74.09')))
bundles$korea_timber<-make('2025_rev_29',list(mk('9903.76.23')))
source('src/section232_semiconductors.R')
for(rev in c('2026_rev_1','2026_rev_4')) {
 b<-make(rev,other_fragments=list(compile_s232_semiconductors_fragment(rev,products)))
 b$coverage<-Filter(function(c)c$authority!='section_232',b$coverage)
 b$coverage<-c(b$coverage,list(list(authority='section_232',status='verified',source_ids=list(sid),
  determination='rules',rule_ids=as.list(vapply(Filter(function(r)r$authority=='section_232',b$rules),`[[`,character(1),'id')))))
 bundles[[paste0(rev,'_actual_semi')]]<-b
}
q<-list(customs_value=100,ieepa_ftz_entry=FALSE,ieepa_personal_accompanied_baggage=FALSE,
 ieepa_qualifying_humanitarian_donation=FALSE,ieepa_informational_material=FALSE,ieepa_de_minimis_claimed=FALSE,
 reciprocal_cbp_transshipment_evasion_determination=FALSE,reciprocal_partner_civil_aircraft_gn6_excluding_unmanned=FALSE)
add<-function(name,rev,at,country='5700',hts10=products[1],facts=q,subtotal=10,codes='9903.01.25',missing=character(),program_verified=FALSE) {
 cat('Checking:',name,'\n');flush.console()
 if(is.null(prepared[[rev]]))prepared[[rev]]<<-prepare_shipment_bundle(bundles[[rev]])
 r<-evaluate_shipment_prepared(prepared[[rev]],hts10,country,at,facts)
 actual<-sort(unique(unlist(lapply(Filter(function(x)x$authority=='ieepa_reciprocal'&&x$status=='applied',r$components),`[[`,'reporting_codes'))))
 if(abs(r$known_subtotal-subtotal)>1e-9||!setequal(actual,codes)||!setequal(r$missing_inputs,missing)) {
  print(list(case=name,codes=actual,result=r[c('status','known_subtotal','missing_inputs','source_errors')]));stop('Later reciprocal regression')
 }
 decision<-Filter(function(c)c$authority=='ieepa_reciprocal',r$coverage_decisions)[[1]]
 stopifnot(is.null(r$complete_total),identical(decision$status=='verified',program_verified))
 if(!rev %in% direct_checked) {
  direct<-evaluate_shipment_bundle(bundles[[rev]],hts10,country,at,facts)
  stopifnot(identical(shipment_result_for_json(direct),shipment_result_for_json(r)))
  direct_checked<<-c(direct_checked,rev)
 }
 cases[[length(cases)+1L]]<<-list(name=name,bundle=rev,hts10=hts10,country=country,entry_at=at,facts=facts,
  expected=list(known_subtotal=subtotal,codes=as.list(actual),missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors)))
}
add('China original suspension immediately before continuation','2025_rev_18','2025-08-12T00:00:59-04:00')
add('China continuation exact instant','2025_rev_18','2025-08-12T00:01:00-04:00')
add('China continuation across September native revision','2025_rev_21','2025-09-02T12:00:00-04:00')
add('China continuation before November extension','2025_rev_28','2025-11-10T00:00:59-05:00')
add('China continuation at November extension','2025_rev_28','2025-11-10T00:01:00-05:00')
add('China suspension continues into next HTS year','2026_rev_1','2026-01-20T12:00:00-05:00')
f<-q;f$reciprocal_partner_civil_aircraft_gn6_excluding_unmanned<-TRUE
add('EU aircraft before retroactive September minute','2025_rev_20','2025-09-01T00:00:59-04:00',country='4280',hts10=products[2],facts=f,subtotal=12.5,codes='9903.02.20')
add('EU aircraft exact retroactive minute in an older snapshot','2025_rev_20','2025-09-01T00:01:00-04:00',country='4280',hts10=products[2],facts=f,subtotal=0,codes='9903.02.76')
add('EU aircraft same rule in next native revision','2025_rev_21','2025-09-02T12:00:00-04:00',country='4280',hts10=products[2],facts=f,subtotal=0,codes='9903.02.76')
add('EU aircraft eligibility does not exempt other origins','2025_rev_21','2025-09-02T12:00:00-04:00',hts10=products[2],facts=f)
add('EU non-aircraft listed hose retains ordinary reciprocal floor','2025_rev_21','2025-09-02T12:00:00-04:00',country='4280',hts10=products[2],subtotal=12.5,codes='9903.02.20')
f$reciprocal_partner_civil_aircraft_gn6_excluding_unmanned<-NULL
add('EU matched aircraft predicate is requested rather than guessed','2025_rev_21','2025-09-02T12:00:00-04:00',country='4280',hts10=products[2],facts=f,subtotal=0,codes=character(),missing='reciprocal_partner_civil_aircraft_gn6_excluding_unmanned')
f$reciprocal_partner_civil_aircraft_gn6_excluding_unmanned<-TRUE
add('Japan aircraft before source agreement minute','2025_rev_23','2025-09-16T00:00:59-04:00',country='5880',hts10=products[2],facts=f,subtotal=12.5,codes='9903.02.73')
add('Japan aircraft exact source agreement minute','2025_rev_23','2025-09-16T00:01:00-04:00',country='5880',hts10=products[2],facts=f,subtotal=0,codes='9903.96.02')
add('Korea additive predecessor before November14','2025_rev_29','2025-11-13T12:00:00-05:00',country='5800',hts10=products[2],subtotal=15,codes='9903.02.56')
add('Korea retroactive floor starts within source revision','2025_rev_29','2025-11-14T00:01:00-05:00',country='5800',hts10=products[2],subtotal=12.5,codes='9903.02.80')
add('Switzerland replaces39 percent predecessor','2025_rev_29','2025-11-13T12:00:00-05:00',country='4419',hts10=products[2],subtotal=39,codes='9903.02.58')
add('Switzerland source floor replaces rather than stacks','2025_rev_29','2025-11-14T00:01:00-05:00',country='4419',hts10=products[2],subtotal=12.5,codes='9903.02.83')
add('Liechtenstein has its own floor reporting identity','2025_rev_29','2025-11-14T00:01:00-05:00',country='4411',hts10=products[2],subtotal=12.5,codes='9903.02.88')
add('Reciprocal still operative immediately before collection ends','2026_rev_3','2026-02-23T23:59:59-05:00')
add('Named charged timber decision removes reciprocal duty','timber','2025-11-02T12:00:00-05:00',hts10=products[2],subtotal=10,codes='9903.01.33')
add('Outside-timber reporting does not remove reciprocal duty','outside_timber','2025-11-02T12:00:00-05:00',hts10=products[2])
add('Zero-payable named MHDV parts remain covered','mh_zero','2025-11-02T12:00:00-05:00',hts10=products[2],subtotal=0,codes='9903.01.33')
add('Korea timber amendment has its own named decision','korea_timber','2025-11-14T00:01:00-05:00',country='5800',hts10=products[2],subtotal=0,codes='9903.01.33')
f<-c(q,list(contains_logic_integrated_circuit=TRUE,all_logic_ic_specs_reviewed=TRUE,total_processing_performance=15000,
 dram_bandwidth_gb_s=4700,semiconductor_end_use='none'))
add('Actual semiconductor technical charge prioritizes Section232 reciprocal reporting','2026_rev_1_actual_semi','2026-01-20T12:00:00-05:00',hts10=products[4],facts=f,subtotal=25,codes='9903.01.33')
f$semiconductor_end_use<-'us_civil_industrial'
add('Actual semiconductor end-use exclusion retains AnnexII reporting','2026_rev_1_actual_semi','2026-01-20T12:00:00-05:00',hts10=products[4],facts=f,subtotal=0,codes='9903.01.32')
f$semiconductor_end_use<-'none'
add('Collection ending removes reciprocal headings while preserving semiconductor charge','2026_rev_4_actual_semi','2026-02-24T00:00:00-05:00',hts10=products[4],facts=f,subtotal=25,codes=character(),program_verified=TRUE)
for(country in c('5700','4280','5880','5800','4419','4411','1220','2010','4120')) {
 add(paste('Collection ended, all origin cases',country),'2026_rev_4','2026-02-24T00:00:00-05:00',country=country,facts=structure(list(),names=character()),subtotal=0,codes=character(),program_verified=TRUE)
 add(paste('Later revision does not resurrect reciprocal headings',country),'2026_rev_19','2026-09-15T12:00:00-04:00',country=country,facts=structure(list(),names=character()),subtotal=0,codes=character(),program_verified=TRUE)
}
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/ieepa-reciprocal-later.json.gz','w')
 writeLines(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=NA),out);close(out)
}
cat(length(cases),'later reciprocal historical/country/claim cases passed\n')
