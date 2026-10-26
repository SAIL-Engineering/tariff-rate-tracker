source('src/resolve_shipment_duties.R')
fixtures <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)
count <- 0L
for(case in fixtures) {
  prepared <- prepare_shipment_bundle(case$bundle)
  direct <- evaluate_shipment_bundle(case$bundle,case$hts10,case$country,case$entry_at,case$facts)
  indexed <- evaluate_shipment_prepared(prepared,case$hts10,case$country,case$entry_at,case$facts)
  stopifnot(identical(.shipment_canonical(direct),.shipment_canonical(indexed)))
  count <- count+1L
}
# All source-generated authority windows, claims and unresolved paths are run
# through both routes. The index selects scope only; it never prices a duty.
for(file in c('ieepa-reciprocal-initial.json.gz','semiconductor-history.json.gz','auto-history.json.gz','auto-interactions.json.gz','auto-metals.json.gz')) {
  connection <- gzfile(file.path('tests/fixtures/shipment',file),'rt')
  data <- jsonlite::fromJSON(paste(readLines(connection,warn=FALSE),collapse='\n'),simplifyVector=FALSE)
  close(connection)
  prepared <- lapply(data$bundles,prepare_shipment_bundle)
  for(case in data$cases) {
    bundle <- data$bundles[[case$bundle]]
    direct <- evaluate_shipment_bundle(bundle,case$hts10,case$country,case$entry_at,case$facts)
    indexed <- evaluate_shipment_prepared(prepared[[case$bundle]],case$hts10,case$country,case$entry_at,case$facts)
    if(!identical(.shipment_canonical(direct),.shipment_canonical(indexed)))stop('Prepared evaluator differs: ',case$name)
    count <- count+1L
  }
}
cat(count,'direct/prepared evaluator scope and boundary conformance cases passed\n')
