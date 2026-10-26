source('src/resolve_shipment_duties.R')
fixture <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]
b <- fixture$bundle;b$rules <- b$rules[1];b$rules[[1]]$formula <- list(value=5)
b$coverage[[1]]$rule_ids <- list(b$rules[[1]]$id)
b$fact_definitions$copper_content_value <- list(type='number',minimum=0,unit='USD',label='Copper value')
constraint <- list(test=list(op='lte',args=list(list(fact='copper_content_value'),list(fact='customs_value'))),
  inputs=list('copper_content_value','customs_value'),label='Copper value cannot exceed article value')
b$rules[[1]]$input_constraints <- list(constraint)
eval <- function(facts) evaluate_shipment_bundle(b,fixture$hts10,fixture$country,fixture$entry_at,facts)
r <- eval(list(customs_value=100))
stopifnot(identical(r$missing_inputs,'copper_content_value'),r$known_subtotal==0,is.null(r$complete_total))
r <- eval(list(customs_value=100,copper_content_value=101))
stopifnot(setequal(r$missing_inputs,c('copper_content_value','customs_value')),r$known_subtotal==0)
r <- eval(list(customs_value=100,copper_content_value=30))
stopifnot(r$complete_total==5,!length(r$missing_inputs))
b$rules[[1]]$input_constraints[[1]]$test <- list(unresolved_source='test_constraint_source_question')
r <- eval(list(customs_value=100))
stopifnot(!length(r$missing_inputs),any(grepl('test_constraint_source_question',r$source_errors)),is.null(r$complete_total))
b$rules[[1]]$input_constraints[[1]]$test <- list(value=1)
r <- eval(list(customs_value=100))
stopifnot(!length(r$missing_inputs),'non_boolean_constraint' %in% r$source_errors,is.null(r$complete_total))
b$rules[[1]]$input_constraints <- NULL
for(scope in list(list(hts10=list(fixture$hts10)),list(country=list(fixture$country)),
                  list(hts_prefixes=list('12345')),list(list('1234567890')))) {
  b$rules[[1]]$scope <- scope
  r <- eval(list(customs_value=100))
  stopifnot('invalid_scope' %in% r$source_errors,r$known_subtotal==0,is.null(r$complete_total))
}
cat('Nine constraint readiness, source and unsupported-scope checks passed\n')
