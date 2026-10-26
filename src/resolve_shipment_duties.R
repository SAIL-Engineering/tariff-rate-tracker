# Declarative shipment evaluation. No aggregate helpers or policy constants.
# Contract: docs/shipment-rule-contract.md; amounts are USD, not weighted rates.

.shipment_result <- function(bundle = list(), errors = character()) {
  list(contract_version = 'sail.shipment-result/v1',
       dataset_version = bundle$dataset_version, revision = bundle$revision,
       evidence_snapshot_id = bundle$evidence_snapshot_id,
       status = if (length(errors)) 'unresolved_source' else 'complete',
       components = list(), rule_decisions = list(), coverage_decisions = list(), applied_rules = character(), suppressed_rules = character(),
       missing_inputs = character(), required_facts = list(), claim_options = list(), source_errors = errors,
       known_subtotal = 0, complete_total = if (length(errors)) NULL else 0)
}

.shipment_time <- function(x) {
  if (!is.character(x) || length(x) != 1 || is.na(x) ||
      !grepl('^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(Z|[+-]\\d{2}:\\d{2})$', x)) return(NA_real_)
  # R may normalize invalid dates, 24:00 and leap seconds that the TS
  # interpreter rejects. Validate the written local fields before conversion.
  local_day <- substr(x, 1, 10)
  parsed_day <- suppressWarnings(as.Date(local_day, format = '%Y-%m-%d'))
  if (is.na(parsed_day) || format(parsed_day, '%Y-%m-%d') != local_day ||
      as.integer(substr(x, 12, 13)) > 23L ||
      as.integer(substr(x, 15, 16)) > 59L ||
      as.integer(substr(x, 18, 19)) > 59L) return(NA_real_)
  if (!endsWith(x, 'Z') && (as.integer(substr(x, 21, 22)) > 23L ||
                          as.integer(substr(x, 24, 25)) > 59L)) return(NA_real_)
  y <- sub('Z$', '+0000', x)
  y <- sub('([+-][0-9]{2}):([0-9]{2})$', '\\1\\2', y)
  as.numeric(as.POSIXct(y, format = '%Y-%m-%dT%H:%M:%S%z', tz = 'UTC'))
}

# JSON object property order is not meaningful; array order is. Keep duplicate
# detection equivalent to the TypeScript runtime and normalize JSON numbers.
.shipment_canonical <- function(x) {
  if (is.list(x)) {
    if (!is.null(names(x))) x <- x[order(names(x), method = 'radix')]
    return(lapply(x, .shipment_canonical))
  }
  if (is.numeric(x)) return(as.numeric(x))
  x
}

.shipment_scope <- function(scope, hts10, country, at) {
  if (is.null(scope)) return(TRUE)
  exact <- scope$hts_exact; prefixes <- scope$hts_prefixes
  product <- if (is.null(exact) && is.null(prefixes)) TRUE else
    hts10 %in% unlist(exact) || any(vapply(prefixes, function(p) startsWith(hts10, p), logical(1)))
  product && (is.null(scope$countries) || country %in% unlist(scope$countries)) &&
    (is.null(scope$from) || (!is.na(.shipment_time(scope$from)) && at >= .shipment_time(scope$from))) &&
    (is.null(scope$until) || (!is.na(.shipment_time(scope$until)) && at < .shipment_time(scope$until)))
}

.shipment_valid_scope <- function(scope) {
  if (is.null(scope)) return(TRUE)
  if (!is.list(scope) || is.null(names(scope)) || anyDuplicated(names(scope)) ||
      any(!names(scope) %in% c('hts_exact','hts_prefixes','countries','from','until'))) return(FALSE)
  array <- function(x, pattern) is.null(x) ||
    all(vapply(x, function(v) is.character(v) && length(v) == 1 && grepl(pattern, v), logical(1)))
  array(scope$hts_exact, '^[0-9]{10}$') && array(scope$hts_prefixes, '^([0-9]{2}){1,5}$') &&
    array(scope$countries, '^.+$') &&
    (is.null(scope$from) || !is.na(.shipment_time(scope$from))) &&
    (is.null(scope$until) || !is.na(.shipment_time(scope$until))) &&
    (is.null(scope$from) || is.null(scope$until) || .shipment_time(scope$from) < .shipment_time(scope$until))
}

.evaluate_shipment_bundle <- function(bundle, hts10, country, entry_at, facts = list()) {
  fail <- function(message) .shipment_result(bundle, message)
  at <- .shipment_time(entry_at)
  if (!is.character(hts10) || length(hts10) != 1 || !grepl('^[0-9]{10}$', hts10) ||
      !is.character(country) || length(country) != 1 || is.na(at))
    return(fail('invalid_shipment_identity_or_entry_timestamp'))
  if (!identical(bundle$contract_version, 'sail.shipment-rules/v1') ||
      !is.character(bundle$dataset_version) || !nzchar(bundle$dataset_version) ||
      !is.character(bundle$evidence_snapshot_id) || !nzchar(bundle$evidence_snapshot_id) ||
      is.null(bundle$coverage_requirements) || !length(bundle$coverage_requirements) ||
      is.null(bundle$rules) || is.null(bundle$sources) || is.null(bundle$products) || is.null(bundle$countries))
    return(fail('unsupported_or_incomplete_contract'))
  if (!hts10 %in% unlist(bundle$products)) return(fail('product_not_valid_in_revision'))
  if (!country %in% unlist(bundle$countries)) return(fail('origin_not_covered'))
  if (is.null(bundle$valid_from) || is.null(bundle$valid_until) ||
      is.na(.shipment_time(bundle$valid_from)) || is.na(.shipment_time(bundle$valid_until)) ||
      at < .shipment_time(bundle$valid_from) || at >= .shipment_time(bundle$valid_until))
    return(fail('entry_outside_bundle_interval'))
  rules <- list()
  for (rule in bundle$rules) {
    if (is.null(rule$id) || !is.character(rule$id) || !nzchar(rule$id)) return(fail('missing_rule_id'))
    if (!is.null(rules[[rule$id]]) && !identical(.shipment_canonical(rules[[rule$id]]), .shipment_canonical(rule)))
      return(fail(paste0('conflicting_rule:', rule$id)))
    rules[[rule$id]] <- rule
  }
  if (any(!vapply(c(bundle$rules, bundle$coverage), function(x) .shipment_valid_scope(x$scope), logical(1))))
    return(fail('invalid_scope'))
  sources <- list()
  for (s in bundle$sources) {
    if (is.null(s$id) || !is.character(s$id)) return(fail('missing_source_id'))
    if (!is.null(sources[[s$id]]) && !identical(.shipment_canonical(sources[[s$id]]), .shipment_canonical(s))) return(fail(paste0('conflicting_source:', s$id)))
    sources[[s$id]] <- s
  }
  valid_source <- function(id) {
    s <- sources[[id]]
    !is.null(s) && identical(s$status, 'verified') &&
      is.character(s$sha256) && grepl('^[a-f0-9]{64}$', s$sha256) &&
      is.character(s$url) && nzchar(s$url) && is.character(s$citation) && nzchar(s$citation)
  }
  if (!is.list(facts)) return(fail('invalid_shipment_facts'))
  if (!is.null(facts$claims) && !all(vapply(as.list(facts$claims), function(x) is.character(x) && length(x) == 1, logical(1))))
    return(fail('invalid_shipment_claims'))
  for (claim in unlist(facts$claims)) {
    definitions <- Filter(function(c) identical(c$id, claim), bundle$claim_definitions)
    if (length(definitions) != 1 || !length(definitions[[1]]$source_ids) ||
        !all(vapply(definitions[[1]]$source_ids, valid_source, logical(1))) ||
        !length(definitions[[1]]$rule_ids) || !all(unlist(definitions[[1]]$rule_ids) %in% names(rules)))
      return(fail(paste0('claim_not_priced:', claim)))
  }
  result <- .shipment_result(bundle)
  for (claim in bundle$claim_definitions) {
    candidates <- unlist(claim$candidate_rule_ids)
    if (!length(candidates) || !all(candidates %in% names(rules)) ||
        !length(claim$source_ids) || !all(vapply(claim$source_ids, valid_source, logical(1)))) next
    matched <- Filter(function(id) .shipment_scope(rules[[id]]$scope, hts10, country, at), as.list(candidates))
    if (length(matched)) result$claim_options[[length(result$claim_options)+1L]] <- list(
      id=claim$id, label=claim$label, candidate_rule_ids=matched,
      citations=unname(sources[unlist(claim$source_ids)]))
  }
  for (authority in unlist(bundle$coverage_requirements)) {
    matches <- Filter(function(c) identical(c$authority, authority) &&
                        .shipment_scope(c$scope, hts10, country, at), bundle$coverage)
    applicable <- Filter(function(r) identical(r$authority, authority) &&
      .shipment_scope(r$scope, hts10, country, at), rules)
    valid_coverage <- function(c) {
      if (!identical(c$status, 'verified') || !length(c$source_ids) ||
          !all(vapply(c$source_ids, valid_source, logical(1))) || is.null(c$rule_ids)) return(FALSE)
      if (!all(vapply(c$rule_ids, function(id) !is.null(rules[[id]]) &&
          identical(rules[[id]]$authority, authority), logical(1)))) return(FALSE)
      if (identical(c$determination, 'rules')) return(length(c$rule_ids) > 0)
      identical(c$determination, 'no_applicable_rules') && !length(c$rule_ids) && !length(applicable)
    }
    unverified <- !length(matches) || !all(vapply(matches, valid_coverage, logical(1))) ||
        any(!names(applicable) %in% unlist(lapply(matches, `[[`, 'rule_ids')))
    if (unverified) result$source_errors <- c(result$source_errors, paste0('coverage_unverified:', authority))
    result$coverage_decisions[[length(result$coverage_decisions)+1L]] <- list(
      authority=authority, status=if(unverified) 'unresolved_source' else 'verified',
      matched_rule_ids=as.list(sort(names(applicable))), attestations=lapply(matches,function(c) {
        c$citations <- unname(Filter(Negate(is.null),sources[unlist(c$source_ids)])); c
      }))
  }
  val <- function(value = NULL, missing = character(), errors = character())
    list(value = value, missing = missing, errors = errors)
  merge_issue <- function(xs) val(missing = unique(unlist(lapply(xs, `[[`, 'missing'))),
                                  errors = unique(unlist(lapply(xs, `[[`, 'errors'))))
  cache <- new.env(parent = emptyenv()); visiting <- character()
  expr <- function(x) {
    if (!is.list(x)) return(val(errors = 'invalid_expression'))
    keys <- intersect(names(x), c('value', 'fact', 'claim', 'rule_amount', 'rule_applies', 'authority_covered', 'unresolved_source', 'op'))
    if (length(keys) != 1) return(val(errors = 'invalid_expression'))
    if (keys == 'authority_covered') {
      authority <- x$authority_covered
      if (!is.character(authority) || length(authority)!=1 || !nzchar(authority))
        return(val(errors='invalid_coverage_dependency'))
      decisions <- Filter(function(d) identical(d$authority,authority),result$coverage_decisions)
      if(length(decisions)!=1 || !identical(decisions[[1]]$status,'verified'))
        return(val(errors=paste0('coverage_dependency_unverified:',authority)))
      return(val(TRUE))
    }
    if (keys == 'unresolved_source') {
      if (!is.character(x$unresolved_source) || length(x$unresolved_source)!=1 || !nzchar(x$unresolved_source))
        return(val(errors='invalid_source_discrepancy'))
      return(val(errors=paste0('source_discrepancy:',x$unresolved_source)))
    }
    if (keys == 'value') {
      if (length(x$value) != 1 || !(is.character(x$value) || is.logical(x$value) || is.numeric(x$value)) ||
          is.na(x$value) || (is.numeric(x$value) && !is.finite(x$value))) return(val(errors = 'invalid_literal'))
      return(val(x$value))
    }
    if (keys == 'claim') {
      claims <- facts$claims
      if (!is.null(claims) && any(!vapply(as.list(claims), is.character, logical(1)))) return(val(missing = 'claims'))
      return(val(x$claim %in% unlist(claims)))
    }
    if (keys == 'fact') {
      key <- x$fact; definition <- bundle$fact_definitions[[key]]; value <- facts[[key]]
      if (is.null(definition)) return(val(errors = paste0('unknown_fact:', key)))
      okay <- length(value) == 1 && !is.na(value)
      if (okay) okay <- switch(definition$type,
        number = is.numeric(value) && is.finite(value), boolean = is.logical(value), string = is.character(value), FALSE)
      if (okay && !is.null(definition$minimum)) okay <- value >= definition$minimum
      if (okay && !is.null(definition$maximum)) okay <- value <= definition$maximum
      if (okay && !is.null(definition$enum)) okay <- value %in% unlist(definition$enum)
      return(if (okay) val(value) else val(missing = key))
    }
    if (keys == 'rule_applies') {
      r <- resolve(x$rule_applies, applicability_only = TRUE)
      return(val(if (r$state == 'unresolved') NULL else r$state == 'applied', r$missing, r$errors))
    }
    if (keys == 'rule_amount') {
      r <- resolve(x$rule_amount)
      return(val(r$amount, r$missing, r$errors))
    }
    op <- x$op; args <- x$args
    if (op == 'if') {
      if (length(args) != 3) return(val(errors = 'invalid_arity:if'))
      test <- expr(args[[1]])
      if (is.null(test$value)) return(test)
      if (!is.logical(test$value)) return(val(errors = 'non_boolean_condition'))
      return(expr(args[[if (test$value) 2 else 3]]))
    }
    arities <- list(subtract = 2, divide = 2, eq = 2, lt = 2, lte = 2, gt = 2, gte = 2, not = 1)
    if (!op %in% c(names(arities), 'add', 'multiply', 'min', 'max', 'and', 'or') ||
        !length(args) || (!is.null(arities[[op]]) && length(args) != arities[[op]]))
      return(val(errors = paste0('invalid_operator_or_arity:', op)))
    xs <- lapply(args, expr)
    if (op %in% c('and', 'or')) {
      decisive <- if (op == 'and') FALSE else TRUE
      if (any(vapply(xs, function(y) identical(y$value, decisive), logical(1)))) return(val(decisive))
    }
    issues <- merge_issue(xs)
    if (length(issues$missing) || length(issues$errors)) return(issues)
    values <- lapply(xs, `[[`, 'value')
    if (op %in% c('and', 'or', 'not')) {
      if (!all(vapply(values, is.logical, logical(1)))) return(val(errors = 'non_boolean_operand'))
    } else if (op != 'eq' && !all(vapply(values, is.numeric, logical(1)))) return(val(errors = 'non_numeric_operand'))
    v <- unlist(values)
    answer <- switch(op, add = sum(v), subtract = v[1] - v[2], multiply = prod(v),
      divide = v[1] / v[2], min = min(v), max = max(v), eq = identical(values[[1]], values[[2]]) ||
        (is.numeric(values[[1]]) && is.numeric(values[[2]]) && values[[1]] == values[[2]]),
      lt = v[1] < v[2], lte = v[1] <= v[2], gt = v[1] > v[2], gte = v[1] >= v[2],
      and = all(v), or = any(v), not = !v[1])
    if (is.numeric(answer) && !is.finite(answer)) return(val(errors = 'non_finite_result'))
    val(answer)
  }
  resolve <- function(id, applicability_only = FALSE) {
    cache_key <- paste0(if (applicability_only) 'applies:' else 'amount:', id)
    if (exists(cache_key, envir = cache, inherits = FALSE)) return(get(cache_key, envir = cache))
    r <- rules[[id]]
    blank <- list(amount = NULL, missing = character(), errors = character(), state = 'unresolved')
    if (is.null(r)) { blank$errors <- paste0('unknown_rule:', id); return(blank) }
    if (cache_key %in% visiting) { blank$errors <- paste0('dependency_cycle:', id); return(blank) }
    visiting <<- c(visiting, cache_key)
    on.exit(visiting <<- setdiff(visiting, cache_key))
    finish <- function(value) { assign(cache_key, value, envir = cache); value }
    if (!.shipment_scope(r$scope, hts10, country, at)) {
      blank$amount <- 0; blank$state <- 'not_applicable'; return(finish(blank))
    }
    # Claims must be reviewed for every matched action, including actions a
    # claim revives and unchanged liabilities. Unknown effects are not zero.
    unpriced <- Filter(function(claim) {
      definition <- Filter(function(c) identical(c$id, claim), bundle$claim_definitions)[[1]]
      !id %in% unlist(definition$rule_ids)
    }, as.list(facts$claims))
    if (length(unpriced)) {
      blank$errors <- paste0('claim_not_priced:', unlist(unpriced), ':', id)
      return(finish(blank))
    }
    if (!identical(r$verification, 'verified') || !length(r$source_ids) || !all(vapply(r$source_ids, valid_source, logical(1))) ||
        is.null(r$action_id) || is.null(r$authority)) {
      blank$errors <- paste0('rule_source_unverified:', id); return(finish(blank))
    }
    condition <- if (is.null(r$when)) val(TRUE) else expr(r$when)
    if (identical(condition$value, FALSE)) {
      blank$amount <- 0; blank$state <- 'not_applicable'; return(finish(blank))
    }
    suppress <- if (is.null(r$suppressed_when)) val(FALSE) else expr(r$suppressed_when)
    if (identical(suppress$value, TRUE)) {
      blank$amount <- 0; blank$state <- 'suppressed'; return(finish(blank))
    }
    if (!identical(condition$value, TRUE) || !identical(suppress$value, FALSE)) {
      blank$missing <- unique(c(condition$missing, suppress$missing))
      blank$errors <- unique(c(condition$errors, suppress$errors))
      if (!is.null(condition$value) && !is.logical(condition$value)) blank$errors <- c(blank$errors, 'non_boolean_condition')
      if (!is.null(suppress$value) && !is.logical(suppress$value)) blank$errors <- c(blank$errors, 'non_boolean_condition')
      return(finish(blank))
    }
    # Liability predicates, not a positive dollar amount, determine precedence.
    # Valuation inputs and constraints are evaluated only when pricing.
    if (applicability_only) {
      blank$amount <- 0; blank$state <- 'applied'; return(finish(blank))
    }
    for (constraint in r$input_constraints) {
      tested <- expr(constraint$test)
      if (!identical(tested$value, TRUE)) {
        # Correction hints apply to a proven contradiction. An unevaluated
        # constraint requests only its missing operands; a source question is
        # not evidence that all shipment inputs are missing or incorrect.
        blank$missing <- sort(unique(c(tested$missing,
          if(identical(tested$value,FALSE)) unlist(constraint$inputs) else character())))
        blank$errors <- tested$errors
        if(!is.null(tested$value) && !is.logical(tested$value)) blank$errors <- c(blank$errors,'non_boolean_constraint')
        return(finish(blank))
      }
    }
    amount <- expr(r$formula)
    blank$missing <- amount$missing; blank$errors <- amount$errors
    if (!is.null(amount$value)) {
      if (!is.numeric(amount$value) || amount$value < 0) blank$errors <- c(blank$errors, 'invalid_duty_amount')
      else { blank$amount <- amount$value; blank$state <- 'applied' }
    }
    finish(blank)
  }
  for (id in sort(names(rules))) {
    r <- rules[[id]]; resolved <- resolve(id)
    if (.shipment_scope(r$scope, hts10, country, at)) {
      result$rule_decisions[[length(result$rule_decisions)+1L]] <- list(
        rule_id=id, action_id=r$action_id, authority=r$authority, outcome=resolved$state,
        scope=r$scope, when=r$when, suppressed_when=r$suppressed_when,
        reporting_codes=r$reporting_codes, source_ids=r$source_ids,
        citations=unname(Filter(Negate(is.null), sources[unlist(r$source_ids)])),
        missing_inputs=resolved$missing, source_errors=resolved$errors)
    }
    if (resolved$state == 'not_applicable') next
    result$components[[length(result$components) + 1L]] <- list(
      rule_id = id, action_id = r$action_id, authority = r$authority, kind = r$kind,
      amount = resolved$amount, status = resolved$state, formula = r$formula,
      reporting_codes = r$reporting_codes, citations = unname(Filter(Negate(is.null), sources[unlist(r$source_ids)])),
      missing_inputs = resolved$missing, source_errors = resolved$errors)
    result$missing_inputs <- c(result$missing_inputs, resolved$missing)
    result$source_errors <- c(result$source_errors, resolved$errors)
    if (resolved$state == 'applied') result$applied_rules <- c(result$applied_rules, id)
    if (resolved$state == 'suppressed') result$suppressed_rules <- c(result$suppressed_rules, id)
    if (!is.null(resolved$amount)) result$known_subtotal <- result$known_subtotal + resolved$amount
  }
  result$missing_inputs <- sort(unique(result$missing_inputs))
  result$required_facts <- bundle$fact_definitions[intersect(result$missing_inputs, names(bundle$fact_definitions))]
  result$source_errors <- sort(unique(result$source_errors))
  result$status <- if (length(result$source_errors)) 'unresolved_source' else
    if (length(result$missing_inputs)) 'needs_inputs' else 'complete'
  result['complete_total'] <- list(if (result$status == 'complete') result$known_subtotal else NULL)
  result
}

evaluate_shipment_bundle <- function(bundle, hts10, country, entry_at, facts = list()) {
  tryCatch(.evaluate_shipment_bundle(bundle, hts10, country, entry_at, facts),
    error = function(e) .shipment_result(if (is.list(bundle)) bundle else list(), 'invalid_shipment_rule_bundle'))
}

resolve_shipment_duties <- function(normalized_dir, hts10, country, entry_at, facts = list()) {
  path <- file.path(normalized_dir, 'shipment_rules.json')
  if (!file.exists(path)) return(.shipment_result(errors = 'missing_shipment_rule_bundle'))
  bundle <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(bundle)) return(.shipment_result(errors = 'invalid_shipment_rule_bundle'))
  evaluate_shipment_bundle(bundle, hts10, country, entry_at, facts)
}
