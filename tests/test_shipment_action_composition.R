source('src/compile_shipment_rules.R')
fragment <- read_shipment_rule_fragment('resources/shipment_rules/s232_semiconductors.json')
base <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json', simplifyVector=FALSE)[[1]]$bundle
base$products <- as.list(c('8471500150','8471801000','8473301180','8471410150'))
base$countries <- as.list(c('5700','5820','1220','2010','4280'))
base$evidence_snapshot_id <- paste(rep('0',64),collapse='')
base$dataset_version <- 'synthetic-composition-v1'
base$valid_from <- '2026-01-01T00:00:00Z'
base$rules <- lapply(seq_along(c('9903.94.05','9903.01.24','9903.88.03','9903.03.12')), function(i) {
  list(id=paste0('synthetic-',i),action_id=paste0('synthetic-',i),authority='synthetic',kind='duty',
    verification='verified',source_ids=list('synthetic'),reporting_codes=as.list(c('9903.94.05','9903.01.24','9903.88.03','9903.03.12')[i]),
    formula=list(op='multiply',args=list(list(fact='customs_value'),list(value=.1))))
})
base$coverage_requirements <- as.list(c('synthetic','section_232','base','section_122','section_301','section_338','adcvd'))
base$coverage[[1]]$rule_ids <- as.list(paste0('synthetic-',1:4))
base$claim_definitions <- list()
bundle <- compose_shipment_rules(base,list(fragment))
stopifnot(length(bundle$rules)==13,length(bundle$relation_decisions)==2,
  !length(Filter(function(c) identical(c$authority,'section_232'),bundle$coverage)))
qualifying <- list(customs_value=100,contains_logic_integrated_circuit=TRUE,all_logic_ic_specs_reviewed=TRUE,
  total_processing_performance=15000,dram_bandwidth_gb_s=4700,semiconductor_end_use='none')
cases <- list()
add <- function(name, facts, subtotal, code, suppressed=as.list(c('synthetic-1','synthetic-2')),
                hts='8471500150', country='5700', at='2026-01-15T00:01:00-05:00', missing=list()) {
  cases[[length(cases)+1L]] <<- list(name=name,facts=facts,hts10=hts,country=country,entry_at=at,
    expected=list(status='unresolved_source',complete_total=NULL,known_subtotal=subtotal,
      reporting_code=code,suppressed_rules=suppressed,missing_inputs=missing))
}
add('qualifying IC suppresses only listed actions',qualifying,45,'9903.79.01')
for(country in unlist(base$countries)) add(paste('country',country),qualifying,45,'9903.79.01',country=country)
for(hts in unlist(base$products)[1:3]) add(paste('legal prefix',hts),qualifying,45,'9903.79.01',hts=hts)
for(tpp in c(14000,17500,20800,21100)) {
 f<-qualifying;f$total_processing_performance<-tpp
 add(paste('strict TPP boundary',tpp),f,40,'9903.79.02',list())
}
for(bw in c(4500,5000,5800,6200)) {
 f<-qualifying;f$dram_bandwidth_gb_s<-bw
 add(paste('strict DRAM boundary',bw),f,40,'9903.79.02',list())
}
f<-qualifying;f$total_processing_performance<-20900;f$dram_bandwidth_gb_s<-6000
add('second technical window',f,45,'9903.79.01')
uses<-unlist(fragment$fact_definitions$semiconductor_end_use$enum)[-1]
for(i in seq_along(uses)) { f<-qualifying;f$semiconductor_end_use<-uses[i];f$data_center_new_ai_load_mw<-101
 add(paste('end use',uses[i]),f,40,paste0('9903.79.',sprintf('%02d',i+2)),list()) }
f<-qualifying;f$semiconductor_end_use<-'us_data_center';f$data_center_new_ai_load_mw<-100
add('100 MW does not meet greater-than threshold',f,45,'9903.79.01')
f$data_center_new_ai_load_mw<-NULL
add('data center requires its statutory load',f,20,NULL, list(),missing=list('data_center_new_ai_load_mw'))
f<-qualifying;f$customs_value<-0
add('zero value still suppresses other actions',f,0,'9903.79.01')
f$customs_value<-NULL
add('missing value cannot revive excluded actions',f,0,'9903.79.01',missing=list('customs_value'))
f<-list(customs_value=100,contains_logic_integrated_circuit=FALSE)
add('no logic IC requires no technical or end-use inputs',f,40,'9903.79.02',list())
f<-list(customs_value=100)
add('unresolved technical scope cannot price dependent actions',f,20,NULL,list(),missing=list('contains_logic_integrated_circuit'))
f<-qualifying;f$all_logic_ic_specs_reviewed<-FALSE
add('unreviewed IC inventory cannot establish exclusion',f,20,NULL,list(),missing=list('all_logic_ic_specs_reviewed'))
add('adjacent uncovered prefix retains other actions',qualifying,40,NULL,list(),hts='8471410150')
add('first legal minute boundary',qualifying,40,NULL,list(),at='2026-01-15T00:00:59-05:00')
f<-qualifying;f$modeled_semi_qualifying_share<-0;f$modeled_semi_end_use_exemption_share<-1
add('modeled shares cannot change shipment liability',f,45,'9903.79.01')
for(case in cases) {
 result<-evaluate_shipment_bundle(bundle,case$hts10,case$country,case$entry_at,case$facts)
 for(key in setdiff(names(case$expected),'reporting_code')) {
  wanted<-unlist(case$expected[[key]],use.names=FALSE);actual<-result[[key]]
  okay<-if(!length(wanted)) !length(actual) else if(is.numeric(wanted)) abs(wanted-actual)<1e-9 else identical(wanted,actual)
  if(!okay) stop(case$name,': ',key,' got ',paste(actual,collapse=','))
 }
 codes<-unlist(lapply(Filter(function(c) c$action_id=='s232_semiconductors_20260115',result$components),`[[`,'reporting_codes'))
 if(!is.null(case$expected$reporting_code)) stopifnot(case$expected$reporting_code %in% codes)
 stopifnot(setequal(names(result$required_facts),result$missing_inputs))
}
# Conflicts, source mutations and missing relation evidence must stop compilation.
bad<-fragment;bad$relations[[1]]$when_rule_applies<-'absent'
stopifnot(inherits(try(compose_shipment_rules(base,list(bad)),silent=TRUE),'try-error'))
bad<-fragment;bad$fact_definitions$customs_value$unit<-'EUR'
stopifnot(inherits(try(compose_shipment_rules(base,list(bad)),silent=TRUE),'try-error'))
shuffled<-fragment;shuffled$rules<-rev(shuffled$rules);shuffled$sources<-rev(shuffled$sources)
stopifnot(identical(.shipment_canonical(bundle),.shipment_canonical(compose_shipment_rules(base,list(shuffled)))))
# Snapshot is reusable through local DuckDB/API and SAIL's independent runtime.
if ('--emit' %in% commandArgs(trailingOnly=TRUE)) jsonlite::write_json(
  list(bundle=bundle,cases=cases), 'tests/fixtures/shipment/semiconductor-composition.json',
  auto_unbox=TRUE,pretty=TRUE,null='null',digits=NA)
cat(length(cases),'source-backed semiconductor scope / synthetic interaction cases passed\n')
# The parts-use relation supplies no guessed rate/date/country treatment. It
# constrains an already sourced action and restores it only when its own facts
# and the semiconductor exclusion permit it.
auto_fragment <- read_shipment_rule_fragment('resources/shipment_rules/s232_auto_parts_condition.json')
auto_bundle <- compose_shipment_rules(base,list(fragment,auto_fragment))
q <- qualifying
r <- evaluate_shipment_bundle(auto_bundle,'8471500150','5700','2026-01-15T00:01:00-05:00',q)
stopifnot(r$known_subtotal==45,!length(r$missing_inputs),'synthetic-1' %in% r$suppressed_rules)
q$contains_logic_integrated_circuit <- FALSE
r <- evaluate_shipment_bundle(auto_bundle,'8471500150','5700','2026-01-15T00:01:00-05:00',q)
stopifnot(r$known_subtotal==30,'is_part_for_passenger_vehicle_or_light_truck' %in% r$missing_inputs)
q$is_part_for_passenger_vehicle_or_light_truck <- FALSE
r <- evaluate_shipment_bundle(auto_bundle,'8471500150','5700','2026-01-15T00:01:00-05:00',q)
stopifnot(r$known_subtotal==30,!length(r$missing_inputs),
  Filter(function(d) d$rule_id=='synthetic-1',r$rule_decisions)[[1]]$outcome=='not_applicable')
q$is_part_for_passenger_vehicle_or_light_truck <- TRUE
r <- evaluate_shipment_bundle(auto_bundle,'8471500150','5700','2026-01-15T00:01:00-05:00',q)
stopifnot(r$known_subtotal==40,!length(r$missing_inputs))
cat('Four automobile-use and semiconductor revival checks passed\n')
