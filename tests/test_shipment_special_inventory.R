suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/shipment_build.R');source('src/04_parse_products.R')
x <- load_shipment_base_source('2026_rev_19')
# Full source inventory only: no rates or timeseries are built.
parsed <- parse_products('data/hts_archives/hts_2026_rev_19.json')
ordinary <- vapply(x$products,`[[`,character(1),'hts10')
special <- vapply(x$special_classifications,`[[`,character(1),'hts10')
stopifnot(length(special)>100L,setequal(parsed$hts10,c(ordinary,special)))
chosen <- c('8703230190',special[1])
f <- compile_shipment_base_fragment(x,chosen,'2010')
b <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$revision <- '2026_rev_19';b$dataset_version <- 'source-special-inventory-probe';b$products <- as.list(chosen);b$countries <- list('2010')
b$valid_from <- f$supported_from;b$valid_until <- f$supported_until;b$rules <- b$coverage <- b$claim_definitions <- list();b$fact_definitions <- list()
b$coverage_requirements <- as.list(SHIPMENT_BUILD_AUTHORITIES);b <- compose_shipment_rules(b,list(f))
r <- evaluate_shipment_bundle(b,special[1],'2010','2026-09-15T12:00:00-04:00',list(customs_value=100,ieepa_ftz_entry=FALSE))
stopifnot(is.null(r$complete_total),r$known_subtotal==0,r$status=='unresolved_source',
 any(grepl('chapter98_entitlement_valuation_and_cross_program_reconciliation',r$source_errors,fixed=TRUE)))
cat('Full native product inventory reconciled; conditional Chapter98 source remains unpriced\n')
