# EO14289's original defined aluminum actions include Proclamation10522.
# Technical competing-action fixture: this does not assert actual metal scope.
source('src/helpers.R');source('src/compile_shipment_rules.R');source('src/section232_mhd_vehicles.R');source('src/section232_mhd_parts.R')
products<-c('4009120020','8705900080','8702103100')
v<-compile_s232_mhd_vehicles_fragment('2026_rev_4',products,'2010')
p<-compile_s232_mhd_parts_fragment('2026_rev_4',products)
seed<-list(contract_version='sail.shipment-rules/v1',dataset_version='mhd-stacking-technical-fixture',revision='2026_rev_4',
 evidence_snapshot_id='original-vehicle-and-stacking-sources',valid_from=v$supported_from,valid_until=v$supported_until,
 products=as.list(products),countries=list('2010'),sources=list(),rules=list(),coverage=list(),
 coverage_requirements=list('base','section_232','adcvd'),fact_definitions=list(),claim_definitions=list())
metal<-list(contract_version='sail.shipment-rule-fragment/v1',id='synthetic-russian-aluminum-action',sources=v$sources,source_artifacts=v$source_artifacts,
 rules=list(list(id='synthetic-russian-aluminum',authority='section_232',action_id='synthetic-russian-aluminum',kind='duty',verification='verified',
  scope=list(hts_exact=as.list(products)),when=list(value=TRUE),formula=list(value=200),reporting_codes=list('9903.85.68'),source_ids=v$rules[[1]]$source_ids)),coverage=list())
b<-compose_shipment_rules(seed,list(v,p,metal));prepared<-prepare_shipment_bundle(b)
facts<-list(customs_value=100,ieepa_ftz_entry=FALSE,s232_vehicle_parts_certification='none',s232_mhd_vehicle=TRUE,
 s232_mhd_manufacture_year=2020,s232_mhd_parts_use=TRUE,s232_mhd_usmca_eligible=FALSE)
check<-function(hts,facts,amount) {
 r<-evaluate_shipment_prepared(prepared,hts,'2010','2026-03-01T12:00:00-05:00',facts)
 if(!isTRUE(all.equal(r$known_subtotal,amount))){print(r[c('known_subtotal','missing_inputs','source_errors')]);stop('MHD inherited aluminum-action stacking failed')}
 stopifnot(is.null(r$complete_total))
}
check('8705900080',facts,25);check('8702103100',facts,10);check('4009120020',facts,25)
facts$s232_mhd_usmca_eligible<-TRUE;facts$s232_mhd_knockdown_kit_or_compilation<-FALSE
check('4009120020',facts,0)
facts$s232_mhd_manufacture_year<-2000
check('8705900080',facts,200);check('8702103100',facts,200)
cat('Six MHD inherited Russian-aluminum stacking checks passed\n')
