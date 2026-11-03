source('src/compile_shipment_rules.R')
fixture <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]
base <- fixture$bundle
base$rules <- list(list(id='consumer',action_id='consumer',authority='synthetic',kind='duty',verification='verified',
  scope=list(hts_exact=base$products),formula=list(fact='old_independently_entered_value'),source_ids=list('synthetic'),reporting_codes=list()))
base$claim_definitions <- list();base$coverage <- list()
base$fact_definitions <- list(actual_value=list(type='number',minimum=0),old_independently_entered_value=list(type='number',minimum=0))
edge <- list(expression=list(fact='actual_value'),source_ids=list('synthetic'))
fragment <- list(contract_version='sail.shipment-rule-fragment/v1',id='source-backed-alias',rules=list(),sources=list(),derived_facts=list(old_independently_entered_value=edge))
b <- compose_shipment_rules(base,list(fragment))
stopifnot(identical(b$rules[[1]]$formula,list(fact='actual_value')))
r <- evaluate_shipment_bundle(b,fixture$hts10,fixture$country,fixture$entry_at,
  list(actual_value=5,old_independently_entered_value=99))
stopifnot(r$known_subtotal==5)
with_relation <- base
with_relation$rules[[1]]$reporting_codes <- list('9903.99.01')
related <- fragment
related$relations <- list(list(id='late-predicate',effect='require_predicate',
  predicate=list(op='gt',args=list(list(fact='old_independently_entered_value'),list(value=0))),
  target_reporting_codes=list('9903.99.01'),source_ids=list('synthetic')))
b2 <- compose_shipment_rules(with_relation,list(related))
stopifnot(!any(c('source_window','target_action_ids') %in% names(b2$relation_decisions[[1]])))
r2 <- evaluate_shipment_bundle(b2,fixture$hts10,fixture$country,fixture$entry_at,
  list(actual_value=5,old_independently_entered_value=0))
stopifnot(r2$known_subtotal==5)
replacement <- fragment
replacement$rules <- list(list(id='combined',action_id='combined_ordinary_treatment',authority='synthetic',
  kind='duty',verification='verified',formula=list(value=10),source_ids=list('synthetic'),reporting_codes=list('9903.99.02')))
replacement$relations <- list(list(id='combined-replaces-base',effect='suppress',when_rule_applies='combined',
  target_action_ids=list('consumer'),source_ids=list('synthetic')))
b3 <- compose_shipment_rules(base,list(replacement))
r3 <- evaluate_shipment_bundle(b3,fixture$hts10,fixture$country,fixture$entry_at,list(actual_value=5))
stopifnot(r3$known_subtotal==10,'consumer' %in% r3$suppressed_rules)
inactive <- replacement;inactive$rules[[1]]$when <- list(value=FALSE)
ri <- evaluate_shipment_bundle(compose_shipment_rules(base,list(inactive)),fixture$hts10,fixture$country,
  fixture$entry_at,list(actual_value=5))
stopifnot(ri$known_subtotal==5,!('consumer' %in% ri$suppressed_rules))
ambiguous <- replacement;ambiguous$relations[[1]]$target_reporting_codes <- list('9903.99.02')
e <- tryCatch({compose_shipment_rules(base,list(ambiguous));NULL},error=function(e)e)
stopifnot(inherits(e,'error'),grepl('Invalid action relation',conditionMessage(e),fixed=TRUE))
windowed <- related
windowed$relations[[1]]$source_window <- list(from='2026-07-01T00:00:00Z',until='2026-08-01T00:00:00Z')
e <- tryCatch({compose_shipment_rules(with_relation,list(windowed));NULL},error=function(e)e)
stopifnot(inherits(e,'error'),grepl('requires exact bundle tiling',conditionMessage(e),fixed=TRUE))
before <- with_relation;before$valid_until <- '2026-07-01T00:00:00Z'
stopifnot(is.null(compose_shipment_rules(before,list(windowed))$rules[[1]]$when))
windowed$relations[[1]]$source_ids <- list('unknown')
e <- tryCatch({compose_shipment_rules(before,list(windowed));NULL},error=function(e)e)
stopifnot(inherits(e,'error'),grepl('Invalid action relation',conditionMessage(e),fixed=TRUE))
bad <- function(fragments,pattern) {
  e <- tryCatch({compose_shipment_rules(base,fragments);NULL},error=function(e)e)
  stopifnot(inherits(e,'error'),grepl(pattern,conditionMessage(e),fixed=TRUE))
}
cycle <- fragment;cycle$derived_facts$actual_value <- list(expression=list(fact='old_independently_entered_value'),source_ids=list('synthetic'))
bad(list(cycle),'Cyclic derived shipment fact')
other <- fragment;other$derived_facts$old_independently_entered_value$expression <- list(value=0)
bad(list(fragment,other),'Conflicting derived shipment fact')
other <- fragment;other$derived_facts$old_independently_entered_value$source_ids <- list('unknown')
bad(list(other),'Unverified derived shipment fact')
cat('12 derived fact identity, window, replacement, relation, compatibility, contradiction and source checks passed\n')
