suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/compile_shipment_rules.R');source('src/section232_autos.R')
source('src/section232_revision.R');source('src/section232_legacy.R')
make <- function(rev,product,from,until,modern=TRUE) {
  auto <- compile_s232_autos_fragment(rev,product,c('2010','4280','5880'))
  metal <- if(modern)compile_s232_note16_fragment(load_s232_note16_source(rev),product) else
    compile_s232_legacy_fragment(load_s232_legacy_source(rev),product)
  b <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
  b$revision <- rev;b$dataset_version <- 'actual-auto-metal-source-probe';b$products <- list(product)
  b$countries <- as.list(c('2010','4280','5880'));b$valid_from <- from;b$valid_until <- until
  b$rules <- b$coverage <- b$claim_definitions <- list();b$fact_definitions <- list()
  b$coverage_requirements <- list('base','section_232');compose_shipment_rules(b,list(auto,metal))
}
bundles <- list(modern=make('2026_rev_19','7320103000','2026-09-15T00:00:00-04:00','2026-09-16T00:00:00-04:00'),
  russian=make('2026_rev_19','8708103030','2026-09-15T00:00:00-04:00','2026-09-16T00:00:00-04:00'),
  retro_eu=make('2025_rev_17','8708103020','2025-08-01T00:01:00-04:00','2025-08-02T00:00:00-04:00',FALSE))
# Controlled overlap probe: the truck's actual native base is25percent, so its
# EU additional-duty heading is zero. The metal applicability below is synthetic
# and does NOT assert that this real truck is in a metal annex.
probe <- compile_s232_autos_fragment('2025_rev_17','8704210100','4280',native_interactions=FALSE)
# Start from uncompiled inputs. Copying an already bound bundle retains action
# dependency metadata even after clearing its rules, and must be rejected.
pb <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
pb$revision <- '2025_rev_17';pb$dataset_version <- 'controlled-zero-auto-metal-overlap'
pb$valid_from <- bundles$retro_eu$valid_from;pb$valid_until <- bundles$retro_eu$valid_until
pb$products <- list('8704210100');pb$countries <- list('4280')
pb$rules <- pb$coverage <- pb$claim_definitions <- list();pb$fact_definitions <- list()
pb$coverage_requirements <- list('base','section_232')
sid <- 'synthetic-country-metal-overlap'
pb$sources <- list(list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/metal-overlap',citation='Synthetic competing applicability only; not a legal product-scope oracle'))
pb$rules <- list(list(id=sid,action_id=sid,authority='section_232',kind='duty',verification='verified',
  source_ids=list(sid),reporting_codes=list('9903.81.89'),formula=list(value=50)))
bundles$zero_probe <- compose_shipment_rules(pb,list(probe))
q <- list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_parts_use=TRUE,s232_auto_usmca_eligible=FALSE,
  steel_weight_fraction=1,aluminum_weight_fraction=0,copper_weight_fraction=0,us_steel_origin_fraction=0,
  contains_steel=TRUE,contains_aluminum=FALSE,steel_content_value=100,aluminum_content_value=0,
  steel_processed_from_us_metal=FALSE,aluminum_processed_from_us_metal=FALSE,
  aluminum_primary_smelted_or_cast_russia=FALSE,privileged_ftz_before_20250312=FALSE,privileged_ftz_before_20250604=FALSE)
cases <- list()
add <- function(name,bundle,hts10,country,at,subtotal,facts=q,missing=character()) {
  r <- evaluate_shipment_bundle(bundles[[bundle]],hts10,country,at,facts)
  if(r$known_subtotal!=subtotal||!setequal(r$missing_inputs,missing)) {
    print(list(name=name,result=r[c('known_subtotal','missing_inputs','source_errors')]));stop('Auto/metal priority regression')
  }
  stopifnot(is.null(r$complete_total))
  codes <- sort(unique(unlist(lapply(Filter(function(c)c$authority=='section_232'&&c$status=='applied',r$components),`[[`,'reporting_codes'))))
  cases[[length(cases)+1L]] <<- list(name=name,bundle=bundle,hts10=hts10,country=country,entry_at=at,facts=facts,
    expected=list(known_subtotal=r$known_subtotal,status=r$status,complete_total=NULL,codes=as.list(codes),
      missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors),suppressed_rules=as.list(r$suppressed_rules)))
}
add('actual automobile spring displaces new metal action','modern','7320103000','2010','2026-09-15T12:00:00-04:00',25)
f <- q;f$s232_auto_parts_use <- FALSE
add('same spring non-auto use retains metal action','modern','7320103000','2010','2026-09-15T12:00:00-04:00',50,f)
f <- q;f$s232_auto_usmca_eligible <- TRUE;f$s232_auto_knockdown_kit_or_compilation <- FALSE
add('zero payable individual automobile part still displaces metal','modern','7320103000','2010','2026-09-15T12:00:00-04:00',0,f)
f <- q;f$steel_weight_fraction <- f$aluminum_weight_fraction <- f$copper_weight_fraction <- f$us_steel_origin_fraction <- NULL
add('missing metal reporting facts cannot add another charge','modern','7320103000','2010','2026-09-15T12:00:00-04:00',25,f,
  missing=c('steel_weight_fraction','aluminum_weight_fraction','copper_weight_fraction'))
add('retroactive EU country heading displaces metal before native insertion','retro_eu','8708103020','4280','2025-08-01T12:00:00-04:00',12.5)
v <- list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_passenger_vehicle=TRUE,s232_auto_manufacture_year=2020)
add('synthetic overlap probe: zero country heading still removes named metal duty','zero_probe','8704210100','4280','2025-08-01T12:00:00-04:00',0,v)
f <- q;f$steel_weight_fraction <- 0;f$aluminum_weight_fraction <- 1;f$us_aluminum_origin_fraction <- 0
f$aluminum_primary_smelted_or_cast_russia <- TRUE
add('Russian-content bumper keeps action-level automobile priority','russian','8708103030','2010','2026-09-15T12:00:00-04:00',25,f)
f$s232_auto_parts_use <- FALSE
add('non-auto Russian-content use retains Russian aluminum duty','russian','8708103030','2010','2026-09-15T12:00:00-04:00',200,f)
f$s232_auto_parts_use <- TRUE;f$s232_auto_usmca_eligible <- TRUE;f$s232_auto_knockdown_kit_or_compilation <- FALSE
add('zero eligible auto part does not revive Russian-content duty','russian','8708103030','2010','2026-09-15T12:00:00-04:00',0,f)
if('--emit' %in% commandArgs(TRUE)) {
  file <- gzfile('tests/fixtures/shipment/auto-metals.json.gz','w')
  writeLines(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=17),file);close(file)
}
cat(length(cases),'actual-source automobile/metal precedence regressions passed\n')
