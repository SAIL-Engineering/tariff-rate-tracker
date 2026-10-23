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
