source('src/helpers.R');source('src/shipment_build.R')
precise <- 1.2345678901234567
stopifnot(identical(jsonlite::fromJSON(.shipment_json(list(value=precise)))$value,precise))
# Synthetic arithmetic only: coverage here makes no legal attestation.
literal <- function(x)list(value=x)
fact <- function(x)list(fact=x)
op <- function(name,...)list(op=name,args=list(...))
cv <- fact('customs_value')
rule <- list(id='charge',action_id='charge',authority='section_232',kind='duty',
  verification='verified',source_ids=list('synthetic'),reporting_codes=list(),
  formula=op('multiply',cv,literal(.25)))
bundle <- list(contract_version='sail.shipment-rules/v1',dataset_version='projection-test',
  revision='synthetic',evidence_snapshot_id='synthetic-not-production',
  valid_from='2025-01-01T00:00:00Z',valid_until='2026-01-01T00:00:00Z',
  products=list('1234567890'),countries=list('TEST'),
  sources=list(list(id='synthetic',status='verified',sha256=paste(rep('0',64),collapse=''),
    url='https://example.invalid/arithmetic',citation='Synthetic projection fixture, not law')),
  rules=list(rule),fact_definitions=list(customs_value=list(type='number',minimum=0)),
  claim_definitions=list(),coverage_requirements=list('section_232'),
  coverage=list(list(authority='section_232',status='verified',determination='rules',
    rule_ids=list('charge'),source_ids=list('synthetic'))))
evaluate <- function(b,value=1)evaluate_shipment_bundle(b,'1234567890','TEST',
  '2025-06-01T00:00:00Z',list(customs_value=value,claims=list()))
project <- function(b).shipment_rate_projection(evaluate(b),b)

# Reference-value inactivity cannot prove a zero statutory rate.
b <- bundle;b$rules[[1]]$when <- op('gt',cv,literal(10))
stopifnot(evaluate(b)$complete_total==0,evaluate(b,100)$complete_total==25)
p <- project(b)
stopifnot(is.na(p$statutory_rate_232),is.na(p$statutory_total_rate))
stopifnot('customs_value' %in% attr(p,'missing_inputs'))

# Suppression can also turn off above/below an absolute value boundary.
b <- bundle;b$rules[[1]]$suppressed_when <- op('lte',cv,literal(10))
stopifnot(evaluate(b)$complete_total==0,evaluate(b,100)$complete_total==25,
  is.na(project(b)$statutory_rate_232))

# The same guard reached through an action dependency must not evade proof.
b$rules[[2]] <- rule;b$rules[[2]]$id <- b$rules[[2]]$action_id <- 'dependent'
b$rules[[2]]$formula <- list(rule_amount='charge')
b$coverage[[1]]$rule_ids <- list('charge','dependent')
stopifnot(evaluate(b,100)$complete_total==50,is.na(project(b)$statutory_rate_232))
b$rules[[2]]$formula <- rule$formula
b$rules[[2]]$when <- list(rule_applies='charge')
stopifnot(evaluate(b,100)$complete_total==50,is.na(project(b)$statutory_total_rate))

# Constraints may invalidate the reference price at an actual shipment value.
b <- bundle;b$rules[[1]]$input_constraints <- list(list(test=op('lte',cv,literal(10)),inputs=list('customs_value')))
stopifnot(evaluate(b)$complete_total==.25,evaluate(b,100)$status=='needs_inputs',
  is.na(project(b)$statutory_rate_232))

# A formula with an absolute threshold is not a constant percentage either.
b <- bundle;b$rules[[1]]$formula <- op('if',op('gt',cv,literal(10)),rule$formula,literal(0))
stopifnot(evaluate(b,100)$complete_total==25,is.na(project(b)$statutory_rate_232))

# Homogeneous comparisons, proportional caps and explicitly unclaimed paths
# remain priceable; do not replace a failed proof with numerical sampling.
b <- bundle;b$rules[[1]]$when <- op('gt',cv,literal(0))
b$rules[[1]]$input_constraints <- list(list(test=op('lte',op('multiply',cv,literal(.5)),cv),inputs=list('customs_value')))
b$rules[[1]]$formula <- op('if',op('gt',cv,literal(0)),
  op('min',rule$formula,op('multiply',cv,literal(.4))),literal(0))
stopifnot(project(b)$statutory_rate_232==.25,project(b)$statutory_total_rate==.25)
b <- bundle;b$rules[[1]]$when <- op('or',op('not',list(claim='VALUE_CLAIM')),op('gt',cv,literal(10)))
stopifnot(project(b)$statutory_rate_232==.25)
b$rules[[1]]$formula <- op('if',list(claim='VALUE_CLAIM'),op('min',literal(10),rule$formula),rule$formula)
stopifnot(project(b)$statutory_total_rate==.25)
# Rollups use the evaluator's exact amounts, not the already rounded component
# numbers. Three recurring fractional action amounts must also sum exactly.
b <- bundle;b$rules[[1]]$formula <- op('multiply',cv,literal(.1))
b$rules[[2]] <- rule;b$rules[[2]]$id <- b$rules[[2]]$action_id <- 'second'
b$rules[[2]]$formula <- op('multiply',cv,literal(.2))
b$coverage[[1]]$rule_ids <- list('charge','second')
stopifnot(identical(project(b)$statutory_rate_232,.3),identical(project(b)$statutory_total_rate,.3))
b$rules[[1]]$authority <- 'base'
b$coverage[[1]]$rule_ids <- list('second')
b$coverage_requirements <- list('base','section_232')
b$coverage[[2]] <- list(authority='base',status='verified',determination='rules',
  rule_ids=list('charge'),source_ids=list('synthetic'))
stopifnot(identical(project(b)$statutory_base_rate,.1),
  identical(project(b)$statutory_total_additional,.2))

# The ordinary wide output must request the actual value even when another
# authority's missing coverage already makes the source status unresolved.
wide <- function(b) {
  other <- setdiff(SHIPMENT_BUILD_AUTHORITIES,unlist(b$coverage_requirements))
  b$coverage <- c(b$coverage,lapply(other,function(a)list(authority=a,status='verified',
    determination='no_applicable_rules',rule_ids=list(),source_ids=list('synthetic'))))
  b$coverage_requirements <- as.list(SHIPMENT_BUILD_AUTHORITIES)
  b$bundle_id <- .shipment_source_signature(b)
  dir <- tempfile();dir.create(dir);on.exit(unlink(dir,recursive=TRUE))
  name <- paste0('shipment_bundle_',b$bundle_id,'.json');path <- file.path(dir,name)
  writeLines(.shipment_json(b),path)
  index <- b[c('revision','dataset_version','evidence_snapshot_id','valid_from','valid_until')]
  index$bundles <- list(list(bundle_id=b$bundle_id,path=name,
    sha256=digest::digest(file=path,algo='sha256'),valid_from=b$valid_from,valid_until=b$valid_until))
  rates <- data.frame(hts10='1234567890',country='TEST',base_rate=.987,total_rate=.876,
    statutory_base_rate=.987,statutory_rate_232=.123,statutory_total_rate=.876)
  project_shipment_state(rates,index,dir)
}
b <- bundle;b$rules[[1]]$when <- op('gt',cv,literal(10))
p <- wide(b)
stopifnot(p$rates$shipment_status=='needs_inputs',is.na(p$rates$statutory_rate_232),
  is.na(p$rates$statutory_total_rate),p$rates$base_rate==.987,p$rates$total_rate==.876,
  'customs_value' %in% jsonlite::fromJSON(p$rates$shipment_missing_inputs_json),
  jsonlite::fromJSON(p$classes$decision_json)$complete_total==0)
b$coverage_requirements <- list('section_232','section_301')
p <- wide(b)
stopifnot(p$rates$shipment_status=='unresolved_source',is.na(p$rates$statutory_rate_232),
  'customs_value' %in% jsonlite::fromJSON(p$rates$shipment_missing_inputs_json),
  grepl('coverage_unverified:section_301',p$rates$shipment_source_errors_json,fixed=TRUE))
b <- bundle;b$fact_definitions$value_claimed <- list(type='boolean')
b$rules[[1]]$when <- op('if',fact('value_claimed'),op('gt',cv,literal(10)),literal(TRUE))
p <- wide(b)
stopifnot(identical(jsonlite::fromJSON(p$rates$shipment_missing_inputs_json),'value_claimed'),
  p$rates$shipment_status=='needs_inputs',is.na(p$rates$statutory_rate_232))
# A shared dependency graph must not expand exponentially during the proof.
# Every amount here is 25% of value; repetition is cumulative, not a max rule.
b <- bundle
for(i in seq_len(30L)) {
  r <- rule;r$id <- r$action_id <- paste0('diamond',i)
  previous <- if(i==1L)'charge' else paste0('diamond',i-1L)
  r$formula <- op('divide',op('add',list(rule_amount=previous),list(rule_amount=previous)),literal(2))
  b$rules[[length(b$rules)+1L]] <- r
}
b$coverage[[1]]$rule_ids <- lapply(b$rules,`[[`,'id')
setTimeLimit(elapsed=5,transient=FALSE)
p <- project(b)
setTimeLimit(cpu=Inf,elapsed=Inf,transient=FALSE)
stopifnot(identical(p$statutory_rate_232,31*.25),identical(p$statutory_total_rate,31*.25))
cat('Shipment scalar projections respect applicability, suppression, dependency, constraint and formula scaling\n')
