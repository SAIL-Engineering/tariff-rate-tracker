suppressPackageStartupMessages(library(here))
source('src/helpers.R');source('src/compile_shipment_rules.R');source('src/shipment_build.R')
x <- load_shipment_base_source('2025_rev_8')
products <- c('8703230190','2203000030','0106199120')
f <- compile_shipment_base_fragment(x,products,c('2010','2390'))
# Base-only interpretation fixture. A production bundle must require the full
# authority inventory; this fixture's complete_total is only the base component.
b <- list(contract_version='sail.shipment-rules/v1',dataset_version='base-source-test',revision='2025_rev_8',
  evidence_snapshot_id='base-source-test-not-production',valid_from='2025-04-09T00:00:00-04:00',
  valid_until='2025-04-10T00:00:00-04:00',products=as.list(products),countries=list('2010','2390'),
  sources=list(),rules=list(),fact_definitions=list(),claim_definitions=list(),coverage=list(),coverage_requirements=list('base'))
b_seed <- b
b <- compose_shipment_rules(b,list(f))
eval <- function(hts,country,facts) {
  facts$ieepa_ftz_entry <- FALSE # This fixture expressly prices an ordinary entry.
  evaluate_shipment_bundle(b,hts,country,'2025-04-09T12:00:00-04:00',facts)
}
r <- eval(products[1],'2010',list(customs_value=100))
stopifnot(r$complete_total==2.5,length(r$components)==1,
  r$components[[1]]$citations[[1]]$sha256==x$source$sha256)
r <- eval(products[1],'2390',list(customs_value=100))
stopifnot(r$complete_total==10)
r <- eval(products[2],'2010',list())
stopifnot(r$complete_total==0,!length(r$missing_inputs))
r <- eval(products[2],'2390',list(customs_value=100))
stopifnot(r$status=='needs_inputs',identical(r$missing_inputs,'quantity_liter'),is.null(r$complete_total))
r <- eval(products[2],'2390',list(customs_value=100,quantity_liter=10))
stopifnot(abs(r$complete_total-1.32)<1e-9)
# Source corruption must not be masked by a previously valid source hash.
bad <- x;bad$products[[1]]$general$expression <- '99%'
stopifnot(inherits(try(compile_shipment_base_fragment(bad,products,c('2010','2390')),silent=TRUE),'try-error'))
stopifnot(inherits(try(compile_shipment_base_fragment(x,c(products,'9999999999'),c('2010','2390')),silent=TRUE),'try-error'))
reverse <- compile_shipment_base_fragment(x,rev(products),c('2390','2010','2390'))
stopifnot(identical(.shipment_canonical(f),.shipment_canonical(reverse)))
r <- evaluate_shipment_bundle(b,products[1],'2010','2025-04-09T12:00:00-04:00',list(customs_value=100))
stopifnot(identical(r$missing_inputs,'ieepa_ftz_entry'),is.null(r$complete_total))
r <- evaluate_shipment_bundle(b,products[1],'2010','2025-04-09T12:00:00-04:00',list(customs_value=100,ieepa_ftz_entry=TRUE))
stopifnot('ftz_status'%in%r$missing_inputs,is.null(r$complete_total))
cat('Ten base-source, country, quantity, integrity and entry-type checks passed\n')
# The native Rev16 source prints a stranded .30.30 line under .25 and also
# contains the separately valid .90.30 line. Neither inherited Free nor Column2
# 60% may leak from an unrelated owner. No production code special-cases this.
orphan <- '9401993030';valid <- '9401999030'
x16 <- load_shipment_base_source('2025_rev_16')
f16 <- compile_shipment_base_fragment(x16,c(orphan,valid),'2390')
b16 <- b_seed;b16$revision <- '2025_rev_16';b16$products <- as.list(c(orphan,valid));b16$countries <- list('2390')
b16$rules <- list();b16$sources <- list();b16$coverage <- list();b16$fact_definitions <- list()
calendar <- load_revision_dates(use_policy_dates=TRUE)
day <- calendar$effective_date[calendar$revision=='2025_rev_16']
b16$valid_from <- .shipment_day_start(day);b16$valid_until <- .shipment_day_start(as.Date(day)+1)
entry <- sub('T00:00:00','T12:00:00',b16$valid_from,fixed=TRUE)
b16 <- compose_shipment_rules(b16,list(f16))
r <- evaluate_shipment_bundle(b16,orphan,'2390',entry,list(customs_value=100,ieepa_ftz_entry=FALSE))
stopifnot(r$status=='unresolved_source',is.null(r$complete_total),any(grepl('unrelated_column2_ancestor',r$source_errors)))
r <- evaluate_shipment_bundle(b16,valid,'2390',entry,list(customs_value=100,ieepa_ftz_entry=FALSE))
stopifnot(r$complete_total==45)
cat('Malformed native branch is unpriced; adjacent valid source owner remains45% (base-only fixture)\n')
