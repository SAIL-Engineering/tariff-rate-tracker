source('src/compile_shipment_rules.R')
b <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
s <- b$sources[[1]]
fragment <- function(citation) {
  source <- s;source$citation <- citation
  list(contract_version='sail.shipment-rule-fragment/v1',id=citation,sources=list(source),
    rules=list(),coverage=list(),fact_definitions=list(),claim_definitions=list(),relations=list())
}
a <- fragment('Same instrument, Annex A locator')
z <- fragment('Same instrument, Annex Z locator')
composed <- compose_shipment_rules(b,list(a,z))
stopifnot(identical(.shipment_canonical(composed),.shipment_canonical(compose_shipment_rules(b,list(z,a)))),
  setequal(unlist(composed$sources[[1]]$citation_locators),c(s$citation,a$sources[[1]]$citation,z$sources[[1]]$citation)))
at <- b$valid_from
r <- evaluate_shipment_bundle(composed,'1234567890','TEST',at,list(customs_value=100))
original <- evaluate_shipment_bundle(b,'1234567890','TEST',at,list(customs_value=100))
stopifnot(r$complete_total==original$complete_total,r$status==original$status)
for(key in c('sha256','url','status')) {
  bad <- a;bad$sources[[1]][[key]] <- paste0('changed-',s[[key]])
  stopifnot(inherits(try(compose_shipment_rules(b,list(bad)),silent=TRUE),'try-error'))
}
cat('Shared artifact locators merge deterministically; hash, URL and verification conflicts still fail\n')
