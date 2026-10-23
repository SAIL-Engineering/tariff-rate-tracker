# Declarative shipment evaluation. No aggregate helpers or policy constants.
# Contract: docs/shipment-rule-contract.md; amounts are USD, not weighted rates.

.shipment_result <- function(bundle = list(), errors = character()) {
  list(contract_version = 'sail.shipment-result/v1',
       dataset_version = bundle$dataset_version, revision = bundle$revision,
       evidence_snapshot_id = bundle$evidence_snapshot_id,
       status = if (length(errors)) 'unresolved_source' else 'complete',
       components = list(), applied_rules = character(), suppressed_rules = character(),
       missing_inputs = character(), source_errors = errors,
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
  if (!is.list(scope)) return(FALSE)
  array <- function(x, pattern) is.null(x) ||
    all(vapply(x, function(v) is.character(v) && length(v) == 1 && grepl(pattern, v), logical(1)))
  array(scope$hts_exact, '^[0-9]{10}$') && array(scope$hts_prefixes, '^[0-9]{2,10}$') &&
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
  for (authority in unlist(bundle$coverage_requirements)) {
    matches <- Filter(function(c) identical(c$authority, authority) &&
                        .shipment_scope(c$scope, hts10, country, at), bundle$coverage)
    if (!length(matches) || any(!vapply(matches, function(c)
        identical(c$status, 'verified') && length(c$source_ids) > 0 &&
          all(vapply(c$source_ids, valid_source, logical(1))), logical(1))))
      result$source_errors <- c(result$source_errors, paste0('coverage_unverified:', authority))
  }
  val <- function(value = NULL, missing = character(), errors = character())
    list(value = value, missing = missing, errors = errors)
  merge_issue <- function(xs) val(missing = unique(unlist(lapply(xs, `[[`, 'missing'))),
                                  errors = unique(unlist(lapply(xs, `[[`, 'errors'))))
  cache <- new.env(parent = emptyenv()); visiting <- character()
  expr <- function(x) {
    if (!is.list(x)) return(val(errors = 'invalid_expression'))
    keys <- intersect(names(x), c('value', 'fact', 'claim', 'rule_amount', 'op'))
    if (length(keys) != 1) return(val(errors = 'invalid_expression'))
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
  resolve <- function(id) {
    if (exists(id, envir = cache, inherits = FALSE)) return(get(id, envir = cache))
    r <- rules[[id]]
    blank <- list(amount = NULL, missing = character(), errors = character(), state = 'unresolved')
    if (is.null(r)) { blank$errors <- paste0('unknown_rule:', id); return(blank) }
    if (id %in% visiting) { blank$errors <- paste0('dependency_cycle:', id); return(blank) }
    visiting <<- c(visiting, id)
    on.exit(visiting <<- setdiff(visiting, id))
    finish <- function(value) { assign(id, value, envir = cache); value }
    if (!.shipment_scope(r$scope, hts10, country, at)) {
      blank$amount <- 0; blank$state <- 'not_applicable'; return(finish(blank))
    }
    if (!identical(r$verification, 'verified') || !length(r$source_ids) || !all(vapply(r$source_ids, valid_source, logical(1))) ||
        is.null(r$action_id) || is.null(r$authority)) {
      blank$errors <- paste0('rule_source_unverified:', id); return(finish(blank))
    }
    condition <- if (is.null(r$when)) val(TRUE) else expr(r$when)
    if (identical(condition$value, FALSE)) {
      blank$amount <- 0; blank$state <- 'not_applicable'; return(finish(blank))
    }
    if (!identical(condition$value, TRUE)) {
      blank$missing <- condition$missing; blank$errors <- condition$errors
      if (!is.null(condition$value)) blank$errors <- c(blank$errors, 'non_boolean_condition')
      return(finish(blank))
    }
    suppress <- if (is.null(r$suppressed_when)) val(FALSE) else expr(r$suppressed_when)
    if (identical(suppress$value, TRUE)) {
      blank$amount <- 0; blank$state <- 'suppressed'; return(finish(blank))
    }
    if (!identical(suppress$value, FALSE)) {
      blank$missing <- suppress$missing; blank$errors <- suppress$errors
      if (!is.null(suppress$value)) blank$errors <- c(blank$errors, 'non_boolean_condition')
      return(finish(blank))
    }
    for (constraint in r$input_constraints) {
      tested <- expr(constraint$test)
      if (!identical(tested$value, TRUE)) {
        blank$missing <- sort(unique(c(tested$missing, unlist(constraint$inputs))))
        blank$errors <- tested$errors
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
