source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/section232_autos.R');source('src/section301_labor.R');source('src/compile_shipment_rules.R')
products<-c('8703230190','8704210100','8471500150');origins<-c('2010','5880')
autos<-compile_s232_autos_fragment('2026_rev_19',products,origins)
labor<-compile_s301_labor_fragment('2026_rev_19',products)
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$revision<-'2026_rev_19';b$dataset_version<-'s301fl-auto-source-composition-not-production'
b$products<-as.list(products);b$countries<-as.list(origins);b$valid_from<-labor$supported_from;b$valid_until<-labor$supported_until
b$rules<-b$coverage<-b$claim_definitions<-list();b$fact_definitions<-list();b$coverage_requirements<-list('base','section_232','section_301','adcvd')
b<-compose_shipment_rules(b,list(autos,labor));prepared<-prepare_shipment_bundle(b);cases<-list()
vehicle<-list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_passenger_vehicle=TRUE,s232_auto_manufacture_year=2020)
parts<-list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_parts_use=TRUE,s232_auto_usmca_eligible=FALSE)
add<-function(name,facts=vehicle,hts='8703230190',country='2010',amount=25,exempt=TRUE) {
 r<-evaluate_shipment_prepared(prepared,hts,country,'2026-09-15T12:00:00-04:00',facts)
 fl<-Filter(function(c)startsWith(c$action_id,'s301_forced_labor_')&&c$status=='applied',r$components)
 stopifnot(is.null(r$complete_total),r$known_subtotal==amount,!length(r$missing_inputs))
 if(exempt)stopifnot(length(fl)==1L,fl[[1]]$amount==0,'9903.05.90'%in%unlist(fl[[1]]$reporting_codes))
 else stopifnot(!length(fl),any(grepl('section301_forced_labor_remaining',r$source_errors,fixed=TRUE)))
 cases[[length(cases)+1L]]<<-list(name=name,bundle='actual',hts10=hts,country=country,entry_at='2026-09-15T12:00:00-04:00',facts=facts,expected=shipment_result_for_json(r))
}
add('Actual ordinary Mexican vehicle retains25 and removes forced-labor duty')
f<-vehicle;f$claims<-list('SECTION_232_AUTO_US_CONTENT');f$s232_auto_usmca_eligible<-TRUE
f$s232_auto_commerce_us_content_approved<-TRUE;f$s232_auto_cbp_overstatement_finding<-FALSE;f$s232_auto_us_content_value<-60
add('Approved vehicle content reevaluates both authorities',facts=f,amount=10)
f$s232_auto_us_content_value<-100
add('Zero payable nonUS vehicle content still removes forced-labor duty',facts=f,amount=0)
f<-vehicle;f$s232_auto_passenger_vehicle<-FALSE;f$s232_auto_manufacture_year<-NULL;f$s232_auto_approved_us_content<-TRUE
add('Caller alias cannot convert a nonvehicle shared heading into relief',facts=f,amount=0,exempt=FALSE)
add('Actual auto-use computer is covered',facts=parts,hts='8471500150')
f<-parts;f$s232_auto_usmca_eligible<-TRUE;f$s232_auto_knockdown_kit_or_compilation<-FALSE
add('Zero-payable USMCA individual computer part remains covered',facts=f,hts='8471500150',amount=0)
f<-parts;f$s232_auto_parts_use<-FALSE;f$s232_auto_usmca_eligible<-NULL;f$s232_usmca_auto_parts_not_kits<-TRUE
add('Caller alias cannot exempt the same computer in another use',facts=f,hts='8471500150',amount=0,exempt=FALSE)
add('Native Japanese truck floor yields zero Section232 without losing coverage',country='5880',hts='8704210100',amount=0)
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/section301-labor-auto.json.gz','w')
 writeLines(jsonlite::toJSON(list(bundles=list(actual=b),cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'actual source automobile/forced-labor claim and zero-payable composition cases passed\n')
