source('src/helpers.R');source('src/compile_shipment_rules.R');source('src/section232_autos.R')
products <- c('8703230190','8704210100','8703210150','8471500150','4009120020','4009120050')
origins <- c('2010','1220','5700','5880','4120','4280','5800','5830')
fragment <- compile_s232_autos_fragment('2026_rev_19',products,origins,native_interactions=FALSE)
bundle <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
bundle$revision <- '2026_rev_19';bundle$dataset_version <- 'source-derived-auto-regression'
bundle$products <- as.list(products);bundle$countries <- as.list(origins)
bundle$valid_from <- fragment$supported_from;bundle$valid_until <- fragment$supported_until
bundle$rules <- bundle$coverage <- bundle$claim_definitions <- list();bundle$fact_definitions <- list()
bundle$coverage_requirements <- as.list(c('base','section_232','section_301','ieepa_reciprocal','adcvd'))
bundle <- compose_shipment_rules(bundle,list(fragment))
cases <- list()
vehicle <- list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_passenger_vehicle=TRUE,
  s232_auto_manufacture_year=2020)
parts <- list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_parts_use=TRUE,s232_auto_usmca_eligible=FALSE)
add <- function(name,amount,code,at='2025-05-03T12:00:00-04:00',country='2010',hts10=products[1],
                facts=vehicle,missing=character(),error=NULL) {
  if(!length(facts))facts <- structure(list(),names=character())
  result <- evaluate_shipment_bundle(bundle,hts10,country,at,facts)
  applied <- Filter(function(c)c$authority=='section_232'&&c$status=='applied',result$components)
  codes <- sort(unique(unlist(lapply(applied,`[[`,'reporting_codes'))))
  okay <- identical(result$known_subtotal,as.numeric(amount))&&setequal(codes,code)&&
    setequal(result$missing_inputs,missing)&&is.null(result$complete_total)
  if(!is.null(error))okay <- okay&&any(grepl(error,result$source_errors,fixed=TRUE))
  if(!okay){print(list(name=name,codes=codes,result=result[c('known_subtotal','missing_inputs','source_errors')]));stop('Automobile regression')}
  cases[[length(cases)+1L]] <<- list(bundle='autos',name=name,hts10=hts10,country=country,entry_at=at,facts=facts,
    expected=list(known_subtotal=amount,status=result$status,complete_total=NULL,codes=as.list(codes),
      missing_inputs=as.list(result$missing_inputs),source_errors=as.list(result$source_errors),suppressed_rules=as.list(result$suppressed_rules)))
}
add('before vehicle exact effective minute',0,character(),at='2025-04-03T00:00:59-04:00',facts=list())
add('ordinary vehicle at exact effective minute',25,'9903.94.01',at='2025-04-03T00:01:00-04:00')
for(country in origins)add(paste('ordinary vehicle independent of origin',country),25,'9903.94.01',country=country)
f <- vehicle;f$s232_auto_passenger_vehicle <- FALSE;f$s232_auto_manufacture_year <- NULL
add('non-passenger article needs no manufacture or content facts',0,'9903.94.02',facts=f)
f <- vehicle;f$s232_auto_manufacture_year <- 2000
add('manufacture calendar-year exception',0,'9903.94.04',facts=f)
f$s232_auto_manufacture_year <- 2001
f$s232_auto_entry_calendar_year <- 2025
add('manufacture year not yet25years before January entry',25,'9903.94.01',at='2025-12-31T23:59:59-05:00',facts=f)
f$s232_auto_entry_calendar_year <- 2026
add('same manufacture year qualifies at January1 calendar boundary',0,'9903.94.04',at='2026-01-01T00:00:00-05:00',facts=f)
f$s232_auto_entry_calendar_year <- 2025
add('Pacific entry-record year differs from Eastern new-year instant',25,'9903.94.01',at='2025-12-31T21:30:00-08:00',facts=f)
f$s232_auto_entry_calendar_year <- NULL
add('NewYear requires actual entry-record year without an assumed port clock',0,character(),at='2026-01-01T00:00:00-05:00',facts=f,missing='s232_auto_entry_calendar_year')
f$s232_auto_manufacture_year <- 2020
add('unambiguous modern vehicle needs no extra NewYear fact',25,'9903.94.01',at='2026-01-01T00:00:00-05:00',facts=f)
f$s232_auto_manufacture_year <- 2000.5
add('fractional manufacture year is invalid',0,character(),facts=f,missing='s232_auto_manufacture_year')
f$s232_auto_manufacture_year <- 2026
add('future manufacture year cannot establish earlier-entry liability',0,character(),facts=f,error='invalid_fact_s232_auto_manufacture_year_after_entry_year')
f <- vehicle;f$s232_auto_passenger_vehicle <- NULL
add('missing vehicle use cannot become ordinary zero',0,character(),facts=f,missing='s232_auto_passenger_vehicle')
f <- vehicle;f$claims <- list('SECTION_232_AUTO_US_CONTENT');f$s232_auto_usmca_eligible <- TRUE
f$s232_auto_commerce_us_content_approved <- TRUE;f$s232_auto_cbp_overstatement_finding <- FALSE;f$s232_auto_us_content_value <- 60
add('approved actual non-US content',10,c('9903.94.02','9903.94.03'),facts=f)
f$s232_auto_us_content_value <- 100
add('zero non-US content retains subject reporting',0,c('9903.94.02','9903.94.03'),facts=f)
f$s232_auto_us_content_value <- 101
add('content exceeds full value',0,character(),facts=f,missing=c('s232_auto_us_content_value','customs_value'))
f$s232_auto_us_content_value <- 60;f$s232_auto_commerce_us_content_approved <- FALSE
add('unapproved content cannot establish reporting or relief',0,character(),facts=f,error='auto_us_content_commerce_approval')
f$s232_auto_commerce_us_content_approved <- TRUE;f$s232_auto_cbp_overstatement_finding <- TRUE
add('CBP model/importer overstatement needs operative finding',0,character(),facts=f,error='auto_cbp_overstatement')
add('adjacent unlisted vehicle is not swept into whole8703',0,character(),hts10='8703210150',facts=list())
add('parts before May effective minute',0,character(),hts10='8471500150',at='2025-05-03T00:00:59-04:00',facts=list())
add('computer used as an actual covered automobile part',25,'9903.94.05',hts10='8471500150',facts=parts)
f <- parts;f$s232_auto_parts_use <- FALSE;f$s232_auto_usmca_eligible <- NULL
add('same computer not an automobile part',0,'9903.94.06',hts10='8471500150',facts=f)
add('adjacent HTS10 outside exact parts scope',0,character(),hts10='4009120050',facts=list())
f <- parts;f$s232_auto_usmca_eligible <- TRUE;f$s232_auto_knockdown_kit_or_compilation <- FALSE
add('USMCA eligible individual parts without an inferred origin restriction',0,'9903.94.06',country='5700',hts10='8471500150',facts=f)
f$s232_auto_knockdown_kit_or_compilation <- TRUE
add('USMCA eligibility cannot exempt knockdown kits',25,'9903.94.05',hts10='8471500150',facts=f)
f <- parts;f$s232_auto_usmca_eligible <- NULL
add('parts eligibility is a required shipment fact',0,character(),hts10='8471500150',facts=f,missing='s232_auto_usmca_eligible')
f <- parts;f$column1_duty_amount <- 2.5
for(row in list(list('Japan','5880','2025-09-16','9903.94.43'),list('EU','4280','2025-08-01','9903.94.53'),
                list('Korea','5800','2025-11-01','9903.94.63'),list('Taiwan','5830','2026-05-01','9903.94.67'))) {
  add(paste(row[[1]],'before original amendment minute'),25,'9903.94.05',hts10='8471500150',country=row[[2]],
    at=paste0(row[[3]],'T00:00:59-04:00'),facts=f)
  add(paste(row[[1]],'native Free base at original amendment minute'),15,row[[4]],hts10='8471500150',country=row[[2]],
    at=paste0(row[[3]],'T00:01:00-04:00'),facts=f)
}
f$customs_value <- 1003;f$column1_duty_amount <- 150.45
add('invented caller AVE cannot replace the native Free base',150.45,'9903.94.43',hts10='8471500150',country='5880',
  at='2025-09-16T12:00:00-04:00',facts=f)
f$customs_value <- 0
add('zero value cannot flip a fixed legal rate band',0,'9903.94.43',hts10='8471500150',country='5880',
  at='2025-09-16T12:00:00-04:00',facts=f)
f <- vehicle;f$column1_duty_amount <- 99
add('EU source-defined MFN floor uses native vehicle base',12.5,'9903.94.51',country='4280',
  at='2025-08-01T00:01:00-04:00',facts=f)
add('native truck base above Japan floor adds zero',0,'9903.94.40',hts10='8704210100',country='5880',
  at='2025-09-16T00:01:00-04:00',facts=f)
f$claims <- list('COLUMN1_SPECIAL');f$s232_auto_usmca_eligible <- FALSE
f$s232_auto_column1_preference_eligible <- TRUE
f$s232_auto_column1_preference_properly_claimed <- TRUE;f$column1_duty_amount <- 0
add('Korea Special entitlement is independent of USMCA eligibility',15,'9903.94.61',country='5800',
  at='2025-11-01T00:01:00-04:00',facts=f)
f$s232_auto_column1_preference_properly_claimed <- FALSE
add('requested preference alone cannot establish Korea Special basis',0,character(),country='5800',
  at='2025-11-01T00:01:00-04:00',facts=f,error='auto_korea_column1_special_entitlement')
f$s232_auto_column1_preference_properly_claimed <- TRUE;f$s232_auto_column1_preference_eligible <- FALSE
add('Korea ineligible Special request cannot supply a duty basis',0,character(),country='5800',
  at='2025-11-01T00:01:00-04:00',facts=f,error='auto_korea_column1_special_entitlement')
f$s232_auto_column1_preference_eligible <- NULL
add('Korea Special request needs its own eligibility evidence',0,character(),country='5800',
  at='2025-11-01T00:01:00-04:00',facts=f,missing='s232_auto_column1_preference_eligible')
f <- vehicle;f$s232_uk_auto_quota_allocated <- TRUE
add('UK actual quota allocation',7.5,'9903.94.31',country='4120',at='2025-06-30T00:01:00-04:00',facts=f)
f$s232_uk_auto_quota_allocated <- FALSE
add('UK quota exhausted',25,'9903.94.01',country='4120',at='2025-06-30T00:01:00-04:00',facts=f)
f <- vehicle
add('UK light truck outside quota list does not ask for quota',25,'9903.94.01',hts10='8704210100',country='4120',at='2025-06-30T12:00:00-04:00',facts=f)
f <- parts;f$s232_uk_auto_parts_uk_vehicle_use <- TRUE
add('UK listed part for UK-produced automobile has combined10 duty',10,'9903.94.32',hts10='4009120020',country='4120',
  at='2025-06-30T12:00:00-04:00',facts=f)
f$s232_uk_auto_parts_uk_vehicle_use <- FALSE
add('UK part for other automobile retains ordinary25 additional duty',25,'9903.94.05',hts10='4009120020',country='4120',
  at='2025-06-30T12:00:00-04:00',facts=f)
f$s232_uk_auto_parts_uk_vehicle_use <- NULL
add('UK listed part requires actual automobile origin use',0,character(),hts10='4009120020',country='4120',
  at='2025-06-30T12:00:00-04:00',facts=f,missing='s232_uk_auto_parts_uk_vehicle_use')
f <- parts;f$claims <- list('SECTION_232_AUTO_IMPORT_OFFSET')
add('approved offset allocation is not a modeled rate credit',0,character(),hts10='8471500150',
  at='2025-11-01T12:00:00-04:00',facts=f,error='auto_import_adjustment_offset')
f <- parts;f$metal_share <- .02;f$assembly_credit <- 999;f$auto_usmca_share <- .9
add('model shares and assembly credits cannot alter shipment duty',25,'9903.94.05',hts10='8471500150',facts=f)
f <- vehicle;f$ieepa_ftz_entry <- TRUE
add('FTZ status/history precedes ordinary auto reporting',0,character(),facts=f,error='auto_ftz_admission_status')
f <- vehicle;f$claims <- list('CHAPTER_98');f$chapter98_provision <- '98020060';f$chapter98_properly_claimed <- TRUE
add('Chapter98 full-value exception',25,'9903.94.01',facts=f)
f$chapter98_provision <- '98020080'
add('other Chapter98 terms precede liability priority',0,character(),facts=f,error='auto_chapter98_selected')
if('--emit' %in% commandArgs(trailingOnly=TRUE)) {
  target <- gzfile('tests/fixtures/shipment/auto-history.json.gz','w')
  writeLines(jsonlite::toJSON(list(bundles=list(autos=bundle),cases=cases),auto_unbox=TRUE,null='null',digits=17),target)
  close(target)
}
cat(length(cases),'source-backed automobile/parts boundary and valuation regressions passed\n')
