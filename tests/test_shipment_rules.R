source('src/resolve_shipment_duties.R')
cases <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json', simplifyVector = FALSE)
count <- 0L
for (case in cases) {
  result <- evaluate_shipment_bundle(case$bundle, case$hts10, case$country, case$entry_at, case$facts)
  for (key in names(case$expected)) {
    expected <- case$expected[[key]]
    actual <- result[[key]]
    if (is.list(expected)) expected <- unlist(expected, use.names = FALSE)
    okay <- if (is.numeric(expected)) is.numeric(actual) && abs(expected - actual) < 1e-9 else
      if (length(expected) == 0) length(actual) == 0 else identical(expected, actual)
    if (!okay) stop(case$name, ': ', key, ': expected ', paste(expected, collapse = ','),
                    ', got ', paste(actual, collapse = ','))
  }
  count <- count + 1L
}
stopifnot(resolve_shipment_duties(tempdir(), '1234567890', 'TEST',
                                '2026-06-01T00:00:00Z')$status == 'unresolved_source')
cat(count, 'shipment rule conformance cases passed\n')

# A zero requires an explicit no-action attestation with its own evidence.
b <- cases[[1]]$bundle
b$rules <- list()
b$coverage[[1]]$determination <- 'no_applicable_rules'
b$coverage[[1]]$rule_ids <- list()
r <- evaluate_shipment_bundle(b,cases[[1]]$hts10,cases[[1]]$country,cases[[1]]$entry_at,list())
stopifnot(r$complete_total==0,r$coverage_decisions[[1]]$status=='verified',
  r$coverage_decisions[[1]]$attestations[[1]]$determination=='no_applicable_rules',
  length(r$coverage_decisions[[1]]$attestations[[1]]$citations)>0)
