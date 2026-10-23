# Compose reviewed action data without collapsing distinct duties into a rate.
# Does not infer scope, create coverage attestations, or load aggregate columns.
source('src/resolve_shipment_duties.R')

read_shipment_rule_fragment <- function(path) {
  fragment <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  if (!identical(fragment$contract_version, 'sail.shipment-rule-fragment/v1'))
    stop('Unsupported shipment rule fragment')
  if (!length(fragment$sources) || !length(fragment$source_artifacts)) stop('Missing fragment evidence')
  for (s in fragment$sources) {
    artifacts <- Filter(function(a) identical(a$source_id, s$id), fragment$source_artifacts)
    if (!identical(s$status, 'verified') || !length(artifacts)) stop('Unverified fragment source: ', s$id)
    for (a in artifacts) {
      file <- file.path(dirname(path), a$path)
      if (!file.exists(file) || !identical(a$sha256, s$sha256) ||
          !identical(digest::digest(file = file, algo = 'sha256'), a$sha256))
        stop('Fragment evidence hash mismatch: ', s$id)
    }
  }
  fragment
}

compose_shipment_rules <- function(bundle, fragments) {
  if (!identical(bundle$contract_version, 'sail.shipment-rules/v1')) stop('Unsupported base rule contract')
  merge_by_id <- function(items, label) {
    out <- list()
    for (item in items) {
      if (is.null(item$id) || !nzchar(item$id)) stop('Missing ', label, ' identifier')
      if (!is.null(out[[item$id]]) && !identical(.shipment_canonical(out[[item$id]]), .shipment_canonical(item)))
        stop('Conflicting ', label, ': ', item$id)
      out[[item$id]] <- item
    }
    unname(out[sort(names(out))])
  }
  bundle$sources <- merge_by_id(c(bundle$sources, unlist(lapply(fragments, `[[`, 'sources'), recursive = FALSE)), 'source')
  bundle$rules <- merge_by_id(c(bundle$rules, unlist(lapply(fragments, `[[`, 'rules'), recursive = FALSE)), 'rule')
  for (fragment in fragments) for (key in names(fragment$fact_definitions)) {
    definition <- fragment$fact_definitions[[key]]
    old <- bundle$fact_definitions[[key]]
    # Type/units/ranges must agree; use fragment explanation/citations when
    # generic facts already exist. Never silently reinterpret a supplied fact.
    semantics <- c('type', 'minimum', 'maximum', 'enum', 'unit')
    if (!is.null(old) && !identical(.shipment_canonical(old[intersect(names(old), semantics)]),
        .shipment_canonical(definition[intersect(names(definition), semantics)]))) stop('Conflicting fact definition: ', key)
    bundle$fact_definitions[[key]] <- definition
  }
  relations <- merge_by_id(unlist(lapply(fragments, `[[`, 'relations'), recursive = FALSE), 'relation')
  ids <- vapply(bundle$rules, `[[`, character(1), 'id')
  source_ids <- vapply(bundle$sources, `[[`, character(1), 'id')
  decisions <- list()
  for (edge in relations) {
    if (!edge$effect %in% c('suppress','require_predicate') ||
        (edge$effect == 'suppress' && !edge$when_rule_applies %in% ids) ||
        (edge$effect == 'require_predicate' && is.null(edge$predicate)) ||
        !length(edge$source_ids) || !all(unlist(edge$source_ids) %in% source_ids) ||
        !length(edge$target_reporting_codes)) stop('Invalid action relation: ', edge$id)
    for (i in seq_along(bundle$rules)) {
      target <- bundle$rules[[i]]
      matches <- intersect(unlist(target$reporting_codes), unlist(edge$target_reporting_codes))
      if (!length(matches)) next
      # A rule mixing independent headings must first be split into actions.
      if (length(setdiff(unlist(target$reporting_codes), matches))) stop('Mixed action reporting codes: ', target$id)
      if (edge$effect == 'suppress' && identical(target$id, edge$when_rule_applies)) stop('Self-suppressing action: ', target$id)
      if (edge$effect == 'suppress') {
        condition <- list(rule_applies = edge$when_rule_applies)
        old <- target$suppressed_when
        if (!is.null(old)) condition <- list(op = 'or', args = list(old, condition))
        target$suppressed_when <- condition
      } else {
        condition <- edge$predicate
        if (!is.null(target$when)) condition <- list(op='and',args=list(target$when,condition))
        target$when <- condition
      }
      target$source_ids <- as.list(sort(unique(c(unlist(target$source_ids), unlist(edge$source_ids)))))
      bundle$rules[[i]] <- target
      decisions[[length(decisions) + 1L]] <- list(relation_id = edge$id, rule_id = target$id,
        when_rule_applies = edge$when_rule_applies, effect = edge$effect,
        reporting_codes = as.list(matches), source_ids = edge$source_ids)
    }
  }
  # Adding actions deliberately invalidates incomplete existing inventories.
  # Only a separate legal review may attest all-action authority coverage.
  bundle$coverage <- c(bundle$coverage, unlist(lapply(fragments, `[[`, 'coverage'), recursive = FALSE))
  bundle$relation_decisions <- decisions
  bundle$compiler <- list(id = 'sail.shipment-rule-composer/v1', fragments = lapply(fragments, `[[`, 'id'))
  bundle
}
