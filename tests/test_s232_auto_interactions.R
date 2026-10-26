suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/compile_shipment_rules.R');source('src/section232_autos.R')
source('src/ieepa_fentanyl.R');source('src/ieepa_actions.R');source('src/section122_revision.R');source('src/section338_revision.R')
make <- function(rev,products,other,countries=c('2010','5700','1220')) {
  auto <- compile_s232_autos_fragment(rev,products,countries,native_interactions=FALSE)
  b <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
  b$products <- as.list(products);b$countries <- as.list(countries)
  b$revision <- rev;b$dataset_version <- 'auto-cross-program-source-regression'
  b$valid_from <- other$supported_from;b$valid_until <- other$supported_until
  b$rules <- b$coverage <- b$claim_definitions <- list();b$fact_definitions <- list()
  b$coverage_requirements <- list('base','section_232','ieepa_fentanyl','section_122','section_338')
  b <- compose_shipment_rules(b,list(auto,other))
  # A controlled fixture inventory for dependency arithmetic. This attests only
  # the actions deliberately composed in this test, not production completeness.
  b$coverage <- list(list(authority='section_232',status='verified',determination='rules',
    rule_ids=as.list(vapply(Filter(function(r)r$authority=='section_232',b$rules),`[[`,character(1),'id')),
    source_ids=list(auto$sources[[1]]$id)))
  b
}
emergency <- compile_ieepa_emergency_fragment(load_ieepa_emergency_source('2025_rev_26'),'8471500150')
bundles <- list(emergency=make('2025_rev_26','8471500150',emergency),
  surcharge=make('2026_rev_4','4009120020',compile_s122_fragment(load_s122_revision_source('2026_rev_4'),'4009120020')),
  s338=make('2026_rev_17','8537109130',compile_s338_fragment('2026_rev_17','8537109130')))
base <- compile_shipment_base_fragment(load_shipment_base_source('2026_rev_19'),'4009120020','4120')
bundles$uk_base <- make('2026_rev_19','4009120020',base,'4120')
q <- list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_parts_use=TRUE,s232_auto_usmca_eligible=TRUE,
  s232_auto_knockdown_kit_or_compilation=FALSE,ieepa_origin_rule_confirmed=TRUE,
  ieepa_personal_accompanied_baggage=FALSE,ieepa_qualifying_humanitarian_donation=FALSE,ieepa_informational_material=FALSE,
  ieepa_de_minimis_claimed=FALSE,ieepa_potash=FALSE,ieepa_canada_energy_or_critical_mineral=FALSE,
  ieepa_canada_cbp_evasion_determination=FALSE,ieepa_china_transit_loading_satisfied=FALSE,
  s122_personal_baggage=FALSE,s122_humanitarian_donation=FALSE,s122_informational_material=FALSE,
  s122_chapter98_claimed=FALSE,s122_ftz_entry=FALSE,s122_gn6_civil_aircraft=FALSE,
  s338_personal_baggage=FALSE,s338_chapter98_claimed=FALSE,s338_ftz_entry=FALSE,s338_civil_aircraft_gn6=FALSE,
  # These old, contradictory answers must be ignored when the authoritative
  # automobile source fragment supplies the same decision and content value.
  s232_usmca_auto_parts_not_kits=FALSE,s122_usmca_auto_parts_not_kits=FALSE,s338_usmca_auto_parts_not_kits=FALSE)
cases <- list()
add <- function(name,bundle,hts10,country,at,facts=q,subtotal,program,program_amount,missing=character()) {
  r <- evaluate_shipment_bundle(bundles[[bundle]],hts10,country,at,facts)
  amount <- sum(vapply(Filter(function(c)c$authority==program&&c$status=='applied',r$components),`[[`,numeric(1),'amount'))
  if(r$known_subtotal!=subtotal||amount!=program_amount||!setequal(r$missing_inputs,missing)) {
    print(list(name=name,amount=amount,result=r[c('known_subtotal','missing_inputs','source_errors')]));stop('Automobile cross-program regression')
  }
  stopifnot(is.null(r$complete_total))
  codes <- sort(unique(unlist(lapply(Filter(function(c)c$authority=='section_232'&&c$status=='applied',r$components),`[[`,'reporting_codes'))))
  cases[[length(cases)+1L]] <<- list(name=name,bundle=bundle,hts10=hts10,country=country,entry_at=at,facts=facts,
    expected=list(known_subtotal=r$known_subtotal,status=r$status,complete_total=NULL,codes=as.list(codes),
      missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors),suppressed_rules=as.list(r$suppressed_rules)))
}
add('IEEPA zero eligible parts before stacking amendment','emergency','8471500150','2010','2025-11-01T00:00:59-04:00',subtotal=25,program='ieepa_fentanyl',program_amount=25)
add('IEEPA zero eligible parts at stacking amendment','emergency','8471500150','2010','2025-11-01T00:01:00-04:00',subtotal=0,program='ieepa_fentanyl',program_amount=0)
f <- q;f$s232_auto_parts_use <- FALSE;f$s232_usmca_auto_parts_not_kits <- TRUE
add('IEEPA non-auto use cannot inherit contradictory exemption alias','emergency','8471500150','2010','2025-11-01T12:00:00-04:00',facts=f,subtotal=25,program='ieepa_fentanyl',program_amount=25)
add('122 individual USMCA parts derive their actual exemption','surcharge','4009120020','5700','2026-03-01T12:00:00-05:00',subtotal=0,program='section_122',program_amount=0)
f <- q;f$s232_auto_parts_use <- FALSE;f$s122_usmca_auto_parts_not_kits <- TRUE
add('122 non-auto use cannot inherit contradictory exemption alias','surcharge','4009120020','5700','2026-03-01T12:00:00-05:00',facts=f,subtotal=10,program='section_122',program_amount=10)
add('338 qualifying parts derive exemption before amendment','s338','8537109130','1220','2026-09-15T00:00:59-04:00',subtotal=0,program='section_338',program_amount=0)
f <- q;f$s232_auto_parts_use <- FALSE;f$s338_usmca_auto_parts_not_kits <- TRUE
add('338 non-auto use cannot inherit contradictory exemption alias','s338','8537109130','1220','2026-09-15T00:00:59-04:00',facts=f,subtotal=50,program='section_338',program_amount=50)
add('338 dated removal of exception remains independently additive','s338','8537109130','1220','2026-09-15T00:01:00-04:00',subtotal=50,program='section_338',program_amount=50)
f <- q;f$s232_auto_usmca_eligible <- FALSE;f$s232_uk_auto_parts_uk_vehicle_use <- TRUE
add('UK combined10 replaces actual native2.5 base instead of adding to it','uk_base','4009120020','4120','2026-09-15T12:00:00-04:00',
  facts=f,subtotal=10,program='section_232',program_amount=10)
f$s232_uk_auto_parts_uk_vehicle_use <- FALSE
add('UK part for non-UK automobile retains native base plus25','uk_base','4009120020','4120','2026-09-15T12:00:00-04:00',
  facts=f,subtotal=27.5,program='section_232',program_amount=25)
f$s232_auto_parts_use <- FALSE;f$s232_uk_auto_parts_uk_vehicle_use <- NULL
add('non-auto UK part retains only native ordinary base in this probe','uk_base','4009120020','4120','2026-09-15T12:00:00-04:00',
  facts=f,subtotal=2.5,program='section_232',program_amount=0)
f$s232_auto_parts_use <- TRUE
add('unknown UK auto use cannot leave an unsubstantiated ordinary base subtotal','uk_base','4009120020','4120','2026-09-15T12:00:00-04:00',
  facts=f,subtotal=0,program='section_232',program_amount=0,missing='s232_uk_auto_parts_uk_vehicle_use')
if('--emit' %in% commandArgs(TRUE)) {
  file <- gzfile('tests/fixtures/shipment/auto-interactions.json.gz','w')
  writeLines(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=17),file);close(file)
}
cat(length(cases),'actual-source automobile IEEPA/122/338 interaction regressions passed\n')
