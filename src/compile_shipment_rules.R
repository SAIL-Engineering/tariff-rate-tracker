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
      file <- if(grepl('^/',a$path)) a$path else file.path(dirname(path), a$path)
      if (!file.exists(file) || !identical(a$sha256, s$sha256) ||
          !identical(digest::digest(file = file, algo = 'sha256'), a$sha256))
        stop('Fragment evidence hash mismatch: ', s$id)
    }
  }
  fragment
}

compose_shipment_rules <- function(bundle, fragments) {
  if (!identical(bundle$contract_version, 'sail.shipment-rules/v1')) stop('Unsupported base rule contract')
  for (fragment in fragments) {
    if ((!is.null(fragment$supported_from) && (is.na(.shipment_time(bundle$valid_from)) ||
        .shipment_time(bundle$valid_from)<.shipment_time(fragment$supported_from))) ||
        (!is.null(fragment$supported_until) && (is.na(.shipment_time(bundle$valid_until)) ||
        .shipment_time(bundle$valid_until)>.shipment_time(fragment$supported_until))))
      stop('Bundle exceeds verified fragment horizon: ',fragment$id)
  }
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
  claims <- list()
  for (claim in c(bundle$claim_definitions,unlist(lapply(fragments,`[[`,'claim_definitions'),recursive=FALSE))) {
    if (is.null(claim$id) || !nzchar(claim$id) || !length(claim$source_ids) || !length(claim$rule_ids))
      stop('Missing reviewed claim definition')
    old <- claims[[claim$id]]
    if (!is.null(old) && !identical(old$label,claim$label)) stop('Conflicting claim label: ',claim$id)
    for (key in c('source_ids','rule_ids','candidate_rule_ids'))
      claim[[key]] <- as.list(sort(unique(c(unlist(old[[key]]),unlist(claim[[key]])))))
    claims[[claim$id]] <- claim
  }
  bundle$claim_definitions <- unname(claims)
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
  targets <- list()
  for (i in seq_along(bundle$rules)) for (code in unlist(bundle$rules[[i]]$reporting_codes))
    targets[[code]] <- c(targets[[code]], i)
  decisions <- list()
  for (edge in relations) {
    if (!edge$effect %in% c('suppress','require_predicate','suppress_by_reporting_codes') ||
        (edge$effect == 'suppress' && !edge$when_rule_applies %in% ids) ||
        (edge$effect == 'require_predicate' && is.null(edge$predicate)) ||
        !length(edge$source_ids) || !all(unlist(edge$source_ids) %in% source_ids) ||
        !length(edge$target_reporting_codes) ||
        (!is.null(edge$target_rule_ids) && (!length(edge$target_rule_ids) || !all(unlist(edge$target_rule_ids)%in%ids))) ||
        (!is.null(edge$trigger_test) && !edge$trigger_test %in% c('positive_duty','applicability')) ||
        (edge$effect=='suppress_by_reporting_codes' && (!length(edge$trigger_reporting_codes) ||
          (!is.null(edge$trigger_test) && !edge$trigger_test %in% c('positive_duty','applicability')))))
      stop('Invalid action relation: ', edge$id)
    trigger_ids <- character()
    if(edge$effect=='suppress_by_reporting_codes') {
      trigger_ix <- sort(unique(unlist(targets[unlist(edge$trigger_reporting_codes)])))
      for(j in trigger_ix) {
        if(length(setdiff(unlist(bundle$rules[[j]]$reporting_codes),unlist(edge$trigger_reporting_codes))))
          stop('Mixed trigger reporting codes: ',bundle$rules[[j]]$id)
        trigger_ids <- c(trigger_ids,bundle$rules[[j]]$id)
      }
    }
    for (i in sort(unique(unlist(targets[unlist(edge$target_reporting_codes)])))) {
      target <- bundle$rules[[i]]
      if(!is.null(edge$target_rule_ids) && !target$id %in% unlist(edge$target_rule_ids)) next
      matches <- intersect(unlist(target$reporting_codes), unlist(edge$target_reporting_codes))
      if (!length(matches)) next
      # A rule mixing independent headings must first be split into actions.
      if (length(setdiff(unlist(target$reporting_codes), matches))) stop('Mixed action reporting codes: ', target$id)
      if (edge$effect == 'suppress' && identical(target$id, edge$when_rule_applies)) stop('Self-suppressing action: ', target$id)
      if (edge$effect %in% c('suppress','suppress_by_reporting_codes')) {
        if(edge$effect=='suppress') condition <- if(identical(edge$trigger_test,'positive_duty'))
          list(op='gt',args=list(list(rule_amount=edge$when_rule_applies),list(value=0))) else list(rule_applies = edge$when_rule_applies)
        else {
          if(target$id %in% trigger_ids) stop('Self-suppressing reporting relation: ',edge$id)
          if(!length(trigger_ids)) next # no invented trigger; coverage remains independently required
          condition <- list(op='or',args=lapply(trigger_ids,function(id)
            if(identical(edge$trigger_test,'positive_duty'))
              list(op='gt',args=list(list(rule_amount=id),list(value=0))) else list(rule_applies=id)))
        }
        old <- target$suppressed_when
        if (!is.null(old)) condition <- list(op = 'or', args = if(identical(old$op,'or')) c(old$args,list(condition)) else list(old,condition))
        target$suppressed_when <- condition
      } else {
        condition <- edge$predicate
        if (!is.null(target$when)) condition <- list(op='and',args=if(identical(target$when$op,'and')) c(target$when$args,list(condition)) else list(target$when,condition))
        target$when <- condition
      }
      target$source_ids <- as.list(sort(unique(c(unlist(target$source_ids), unlist(edge$source_ids)))))
      bundle$rules[[i]] <- target
      decisions[[length(decisions) + 1L]] <- list(relation_id = edge$id, rule_id = target$id,
        when_rule_applies = edge$when_rule_applies, effect = edge$effect,
        reporting_codes = as.list(matches), source_ids = edge$source_ids)
    }
  }
  # Explicit, source-backed cross-authority claim effects. Recognize only a
  # registered claim whose candidate rules all belong to the stated authority;
  # a claim-name prefix alone is not evidence of its meaning.
  passthrough <- merge_by_id(unlist(lapply(fragments,`[[`,'unchanged_claims'),recursive=FALSE),'claim relation')
  for(edge in passthrough) {
    if(!length(edge$target_rule_ids)||!all(unlist(edge$target_rule_ids)%in%ids)||
       !length(edge$source_ids)||!all(unlist(edge$source_ids)%in%source_ids)||
       is.null(edge$claim_authority)) stop('Invalid unchanged-claim relation')
    for(i in seq_along(bundle$claim_definitions)) {
      claim<-bundle$claim_definitions[[i]];candidates<-unlist(claim$candidate_rule_ids)
      if(!length(candidates)) next
      crules<-bundle$rules[match(candidates,ids)]
      if(anyNA(match(candidates,ids)) || !all(vapply(crules,function(r) identical(r$authority,edge$claim_authority),logical(1)))) next
      claim$rule_ids<-as.list(sort(unique(c(unlist(claim$rule_ids),unlist(edge$target_rule_ids)))))
      claim$source_ids<-as.list(sort(unique(c(unlist(claim$source_ids),unlist(edge$source_ids)))))
      bundle$claim_definitions[[i]]<-claim
      decisions[[length(decisions)+1L]]<-list(relation_id=edge$id,claim_id=claim$id,
        effect='claim_leaves_liability_unchanged',rule_ids=edge$target_rule_ids,source_ids=edge$source_ids)
    }
  }
  # Adding actions deliberately invalidates incomplete existing inventories.
  # Only a separate legal review may attest all-action authority coverage.
  bundle$coverage <- c(bundle$coverage, unlist(lapply(fragments, `[[`, 'coverage'), recursive = FALSE))
  bundle$relation_decisions <- decisions
  bundle$compiler <- list(id = 'sail.shipment-rule-composer/v1', fragments = lapply(fragments, `[[`, 'id'))
  bundle
}
