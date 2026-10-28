source('src/compile_shipment_rules.R')
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$rules<-b$coverage<-b$claim_definitions<-list();b$fact_definitions<-list();b$coverage_requirements<-list('base','section_232')
b$products<-list('7318158085','0106199120');b$countries<-list('5700');b$dataset_version<-'controlled-entry-context-not-production'
s<-list(id='controlled-context',status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/context',citation='Controlled ordinary-entry capability contract; not a legal rate oracle')
f<-list(contract_version='sail.shipment-rule-fragment/v1',id='controlled-context',sources=list(s),source_artifacts=list(),
 fact_definitions=list(ieepa_ftz_entry=list(type='boolean',label='Entry withdrawn from a foreign-trade zone',source_ids=list(s$id))),
 entry_context=list(mode='ordinary_only',fact='ieepa_ftz_entry',unresolved_source='controlled_ftz_history_uncompiled',source_ids=list(s$id)),
 rules=list(list(id='ordinary-controlled',action_id='ordinary-controlled',authority='section_232',kind='duty',verification='verified',source_ids=list(s$id),
 scope=list(hts_exact=list('7318158085')),formula=list(value=50),reporting_codes=list('9903.82.02'))),coverage=list(),relations=list())
bundle<-compose_shipment_rules(b,list(f))
at<-'2026-01-20T12:00:00-05:00'
missing<-evaluate_shipment_bundle(bundle,'7318158085','5700',at,list())
stopifnot(missing$known_subtotal==0,'ieepa_ftz_entry'%in%missing$missing_inputs,is.null(missing$complete_total))
ordinary<-evaluate_shipment_bundle(bundle,'7318158085','5700',at,list(ieepa_ftz_entry=FALSE))
stopifnot(ordinary$known_subtotal==50,!length(ordinary$missing_inputs))
ftz<-evaluate_shipment_bundle(bundle,'7318158085','5700',at,list(ieepa_ftz_entry=TRUE))
stopifnot(ftz$known_subtotal==0,any(grepl('controlled_ftz_history_uncompiled',ftz$source_errors,fixed=TRUE)))
outside<-evaluate_shipment_bundle(bundle,'0106199120','5700',at,list())
stopifnot(!'ieepa_ftz_entry'%in%outside$missing_inputs)
inactive<-f;inactive$rules[[1]]$when<-list(value=FALSE)
not_applicable<-evaluate_shipment_bundle(compose_shipment_rules(b,list(inactive)),'7318158085','5700',at,list())
stopifnot(!'ieepa_ftz_entry'%in%not_applicable$missing_inputs)
for(change in c('mode','fact','source_ids')) {
 bad<-f;bad$entry_context[[change]]<-NULL
 stopifnot(inherits(try(compose_shipment_rules(b,list(bad)),silent=TRUE),'try-error'))
}
cat('Ordinary-entry capability cannot price unknown or FTZ contexts, and unrelated products request no context facts\n')
