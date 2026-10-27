source('src/resolve_shipment_duties.R')
b <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$rules <- b$rules[1];id <- b$rules[[1]]$id;source_ids <- b$rules[[1]]$source_ids
b$rules[[1]]$formula <- list(value=1)
b$fact_definitions <- list(z_fact=list(type='boolean',label='Z fact',source_ids=source_ids),
  a_fact=list(type='boolean',label='A fact',source_ids=source_ids))
b$coverage_requirements <- list(b$rules[[1]]$authority)
b$coverage <- list(list(authority=b$rules[[1]]$authority,status='verified',determination='rules',
  rule_ids=list(id),source_ids=source_ids))
b$claim_definitions <- list()
cases <- list()
facts <- list(claims=list())
for(kind in c('missing','source_errors')) {
  bundle <- b
  operands <- if(kind=='missing')list(list(fact='z_fact'),list(fact='a_fact'),list(fact='z_fact')) else
    list(list(unresolved_source='z_question'),list(unresolved_source='a_question'),list(unresolved_source='z_question'))
  bundle$rules[[1]]$when <- list(op='and',args=operands)
  hts10 <- unlist(bundle$products)[1];country <- unlist(bundle$countries)[1];at <- bundle$valid_from
  result <- evaluate_shipment_bundle(bundle,hts10,country,at,facts)
  prepared <- evaluate_shipment_prepared(prepare_shipment_bundle(bundle),hts10,country,at,facts)
  stopifnot(identical(.shipment_canonical(result),.shipment_canonical(prepared)))
  expected <- if(kind=='missing')c('a_fact','z_fact') else c('source_discrepancy:a_question','source_discrepancy:z_question')
  field <- if(kind=='missing')'missing_inputs' else 'source_errors'
  stopifnot(identical(result[[field]],expected),
    identical(result$components[[1]][[field]],expected),
    identical(result$rule_decisions[[1]][[field]],expected),is.null(result$complete_total))
  cases[[length(cases)+1L]] <- list(name=kind,bundle=bundle,hts10=hts10,country=country,entry_at=at,
    facts=facts,expected=shipment_result_for_json(result))
}
if('--emit' %in% commandArgs(TRUE))jsonlite::write_json(cases,'tests/fixtures/shipment/diagnostic-ordering.json',
  auto_unbox=TRUE,pretty=TRUE,null='null',digits=17)
cat('Missing facts and source questions have stable unique order in direct/prepared results and nested decisions\n')
