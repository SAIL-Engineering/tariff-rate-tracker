# Compose reviewed action data without collapsing distinct duties into a rate.
# Does not infer scope, create coverage attestations, or load aggregate columns.
source('src/resolve_shipment_duties.R')

validate_shipment_fragment_contract <- function(fragment) {
  spec<-jsonlite::fromJSON(here::here('resources/shipment_rules/fragment_contract.json'),simplifyVector=FALSE)
  version<-fragment$contract_version;features<-unlist(fragment$required_compiler_features,use.names=FALSE)
  if(length(version)!=1L||!version%in%unlist(spec$versions)||any(!features%in%unlist(spec$features))||
     (identical(version,spec$feature_version)&&!length(features))||
     (!identical(version,spec$feature_version)&&length(features)))stop('Unsupported shipment rule fragment capability contract')
  has_node<-function(x,key)is.list(x)&&(key%in%names(x)||any(vapply(x,has_node,logical(1),key=key)))
  if((length(fragment$claim_implications)&&!'claim_implications'%in%features)||
     (has_node(fragment,'rule_predicate')&&!'rule_value_predicates'%in%features))stop('Undeclared required shipment compiler feature')
  invisible(TRUE)
}

read_shipment_rule_fragment <- function(path) {
  fragment <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  validate_shipment_fragment_contract(fragment)
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
  if(length(bundle$compiler$id)==1L&&startsWith(bundle$compiler$id,'sail.shipment-rule-composer/'))
    stop('Cannot add fragments to a compiled shipment bundle; reassemble all original fragments together to rebind action dependencies')
  for (fragment in fragments) {
    validate_shipment_fragment_contract(fragment)
    if ((!is.null(fragment$supported_from) && (is.na(.shipment_time(bundle$valid_from)) ||
        .shipment_time(bundle$valid_from)<.shipment_time(fragment$supported_from))) ||
        (!is.null(fragment$supported_until) && (is.na(.shipment_time(bundle$valid_until)) ||
        .shipment_time(bundle$valid_until)>.shipment_time(fragment$supported_until))))
      stop('Bundle exceeds verified fragment horizon: ',fragment$id)
  }
  # Compiler capability is explicit data. An ordinary-entry fragment cannot
  # silently price a foreign-trade-zone history from the current entry date.
  # Other fragments with verified FTZ branches retain their own decisions.
  fragments <- lapply(fragments,function(fragment) {
    context<-fragment$entry_context
    if(is.null(context))return(fragment)
    own_sources<-vapply(Filter(function(s)identical(s$status,'verified'),fragment$sources),`[[`,character(1),'id')
    if(!identical(context$mode,'ordinary_only')||!is.character(context$fact)||length(context$fact)!=1L||
       !grepl('^[A-Za-z][A-Za-z0-9_]*$',context$fact)||
       !identical(fragment$fact_definitions[[context$fact]]$type,'boolean')||
       !is.character(context$unresolved_source)||length(context$unresolved_source)!=1L||!nzchar(context$unresolved_source)||
       !length(context$source_ids)||!all(unlist(context$source_ids)%in%own_sources))stop('Unverified entry-context capability: ',fragment$id)
    fragment$rules<-lapply(fragment$rules,function(rule) {
      prior<-if(is.null(rule$when))list(value=TRUE) else rule$when
      context_when<-list(op='if',args=list(list(fact=context$fact),list(unresolved_source=context$unresolved_source),list(value=TRUE)))
      rule$when<-list(op='and',args=list(prior,context_when))
      rule$source_ids<-as.list(sort(unique(c(unlist(rule$source_ids),unlist(context$source_ids)))))
      rule
    })
    fragment
  })
  # Accumulate in a hashed environment, not a named list. `out[[id]] <- item`
  # on a list is a linear scan of the names plus a full reallocation per
  # insert, so building one is quadratic: measured 0.18 s at 5,000 items and
  # 11.6 s at 40,000, which extrapolates to ~5.5 minutes for the 214,023
  # relations of a single revision. The returned order is unchanged.
  merge_by_id <- function(items, label) {
    out <- new.env(parent = emptyenv(), hash = TRUE, size = max(29L, length(items)))
    for (item in items) {
      if (is.null(item$id) || !nzchar(item$id)) stop('Missing ', label, ' identifier')
      prior <- if (exists(item$id, envir = out, inherits = FALSE))
        get(item$id, envir = out, inherits = FALSE) else NULL
      if (!is.null(prior) && !identical(.shipment_canonical(prior), .shipment_canonical(item)))
        stop('Conflicting ', label, ': ', item$id)
      assign(item$id, item, envir = out)
    }
    unname(mget(sort(ls(out, all.names = TRUE)), envir = out))
  }
  # One immutable instrument can substantiate several programs at different
  # locators. Merge those locator citations while keeping byte identity, URL,
  # verification and every other source property strict. Runtime bundles still
  # contain one unambiguous source record per ID; no duty rule is merged here.
  merge_sources <- function(items) {
    out <- list()
    for(item in items) {
      if(is.null(item$id)||!nzchar(item$id))stop('Missing source identifier')
      old <- out[[item$id]]
      if(!is.null(old)&&!identical(.shipment_canonical(old),.shipment_canonical(item))) {
        metadata <- function(s)s[setdiff(names(s),c('citation','citation_locators'))]
        if(!identical(.shipment_canonical(metadata(old)),.shipment_canonical(metadata(item))))
          stop('Conflicting source: ',item$id)
        locators <- function(s) {
          xs <- if(is.null(s$citation_locators))as.list(s$citation) else s$citation_locators
          if(!length(xs)||any(!vapply(xs,function(x)is.character(x)&&length(x)==1L&&nzchar(x),logical(1))))
            stop('Invalid source citation locators: ',s$id)
          unlist(xs,use.names=FALSE)
        }
        refs <- sort(unique(c(locators(old),locators(item))))
        item$citation_locators <- as.list(refs);item$citation <- paste(refs,collapse='; ')
      }
      out[[item$id]] <- item
    }
    unname(out[sort(names(out))])
  }
  bundle$sources <- merge_sources(c(bundle$sources, unlist(lapply(fragments, `[[`, 'sources'), recursive = FALSE)))
  bundle$rules <- merge_by_id(c(bundle$rules, unlist(lapply(fragments, `[[`, 'rules'), recursive = FALSE)), 'rule')
  for(r in bundle$rules) if(!is.null(r$reporting_only)) {
    if(!is.logical(r$reporting_only)||length(r$reporting_only)!=1L||is.na(r$reporting_only))stop('Invalid reporting-only role: ',r$id)
    if(isTRUE(r$reporting_only)&&(!identical(names(r$formula),'value')||!is.numeric(r$formula$value)||
       length(r$formula$value)!=1L||is.na(r$formula$value)||r$formula$value!=0))stop('A reporting-only rule cannot carry a duty: ',r$id)
  }
  # Bind source-derived reporting predicates to action identities. Empty matches
  # do not establish legal absence: the pricing expression separately requires
  # a verified authority inventory. This is a compiler construct, not a caller fact.
  overlap <- function(a,b) {
    if(length(a$countries)&&length(b$countries)&&!length(intersect(unlist(a$countries),unlist(b$countries)))) return(FALSE)
    if(!is.null(a$from)&&!is.null(b$until)&&.shipment_time(a$from)>=.shipment_time(b$until)) return(FALSE)
    if(!is.null(b$from)&&!is.null(a$until)&&.shipment_time(b$from)>=.shipment_time(a$until)) return(FALSE)
    if(length(a$hts_exact)&&length(b$hts_exact)&&!length(b$hts_prefixes)&&!length(intersect(unlist(a$hts_exact),unlist(b$hts_exact)))) return(FALSE)
    TRUE
  }
  original_rules <- bundle$rules
  original_rule_ids<-vapply(original_rules,`[[`,character(1),'id')
  reporting_candidates <- split(original_rules,vapply(original_rules,`[[`,character(1),'authority'))
  # A source-backed compiler can establish that an older independently asked
  # input is the same legal decision/value already evaluated by another action.
  # Expand that expression before interpretation; contradictory caller aliases
  # cannot override the authoritative facts. No program names live here.
  derived <- list()
  known_sources <- vapply(Filter(function(s)identical(s$status,'verified'),bundle$sources),`[[`,character(1),'id')
  for(fragment in fragments) for(key in names(fragment$derived_facts)) {
    d <- fragment$derived_facts[[key]]
    if(!grepl('^[A-Za-z][A-Za-z0-9_]*$',key)||is.null(d$expression)||
       !length(d$source_ids)||!all(unlist(d$source_ids)%in%known_sources))
      stop('Unverified derived shipment fact: ',key)
    if(!is.null(derived[[key]])&&!identical(.shipment_canonical(derived[[key]]),.shipment_canonical(d)))
      stop('Conflicting derived shipment fact: ',key)
    derived[[key]] <- d
  }
  used_sources <- character()
  expand_derived <- function(node,visiting=character()) {
    if(!is.list(node))return(node)
    if(length(node)==1L&&!is.null(node$fact)&&is.character(node$fact)&&!is.null(derived[[node$fact]])) {
      key <- node$fact
      if(key %in% visiting)stop('Cyclic derived shipment fact: ',key)
      used_sources <<- union(used_sources,unlist(derived[[key]]$source_ids))
      return(expand_derived(derived[[key]]$expression,c(visiting,key)))
    }
    lapply(node,expand_derived,visiting=visiting)
  }
  for(key in names(derived))expand_derived(list(fact=key))
  bind_reporting <- function(node,scope) {
    if(!is.list(node)) return(node)
    if(!is.null(node$rule_predicate)) {
      p<-node$rule_predicate;requested<-unlist(p$rule_ids,use.names=FALSE)
      if(length(node)!=1L||!setequal(names(p),c('rule_ids','amount_equal'))||!length(requested)||
         any(!requested%in%original_rule_ids)||!is.numeric(p$amount_equal)||length(p$amount_equal)!=1L||
         !is.finite(p$amount_equal))stop('Unverified rule-value predicate')
      selected<-Filter(function(r)r$id%in%requested&&overlap(scope,r$scope),original_rules)
      args<-lapply(selected,function(r)list(op='and',args=list(list(rule_applies=r$id),
        list(op='eq',args=list(list(rule_amount=r$id),list(value=p$amount_equal))))))
      return(if(!length(args))list(value=FALSE) else if(length(args)==1L)args[[1]] else list(op='or',args=args))
    }
    if(!is.null(node$reporting_predicate)) {
      p<-node$reporting_predicate
      if(length(node)!=1 || !identical(p$authority,'section_232') || !length(p$codes) ||
         any(!grepl('^9903\\.[0-9]{2}\\.[0-9]{2}$',unlist(p$codes))) ||
         !is.logical(p$positive_duty)||length(p$positive_duty)!=1 ||
         !is.logical(p$exclude)||length(p$exclude)!=1) stop('Invalid reporting predicate')
      selected<-Filter(function(r)overlap(scope,r$scope),reporting_candidates[[p$authority]])
      # A reporting-only line is not an unidentified additional duty action.
      # Keep it available to expressly named reporting-role predicates, while
      # excluding it from the catch-all for other liability. The source flag
      # above requires a verified literal-zero formula; ordinary zero-payable
      # covered actions do not get this flag.
      if(p$exclude)selected<-Filter(function(r)!isTRUE(r$reporting_only),selected)
      selected<-Filter(function(r) {
        hit<-intersect(unlist(r$reporting_codes),unlist(p$codes))
        if(length(hit)&&length(setdiff(unlist(r$reporting_codes),unlist(p$codes)))) stop('Mixed reporting decision must be split: ',r$id)
        if(p$exclude) !length(hit) else length(hit)>0
      },selected)
      args<-lapply(selected,function(r) if(p$positive_duty)
        list(op='gt',args=list(list(rule_amount=r$id),list(value=0))) else list(rule_applies=r$id))
      return(if(!length(args)) list(value=FALSE) else if(length(args)==1) args[[1]] else list(op='or',args=args))
    }
    lapply(node,bind_reporting,scope=scope)
  }
  rewrite_rule <- function(r) {
    used_sources <<- character()
    for(k in c('when','suppressed_when','formula','input_constraints')) if(!is.null(r[[k]]))
      r[[k]]<-bind_reporting(expand_derived(r[[k]]),r$scope)
    if(length(used_sources))r$source_ids <- as.list(sort(unique(c(unlist(r$source_ids),used_sources))))
    r
  }
  bundle$rules <- lapply(bundle$rules,rewrite_rule)
  if(length(derived))bundle$derived_fact_decisions <- derived
  for(fragment in fragments) if(!is.null(fragment$reciprocal_scope)) {
    scope <- fragment$reciprocal_scope
    if(!identical(scope$contract_version,'sail.ieepa-reciprocal-history/v1') || !identical(scope$revision,bundle$revision))
      stop('Reciprocal scope/revision mismatch')
    old <- bundle$evidence_dependencies$reciprocal_scope
    if(!is.null(old) && !identical(.shipment_canonical(old),.shipment_canonical(scope))) stop('Conflicting reciprocal scope evidence')
    bundle$evidence_dependencies$reciprocal_scope <- scope
  }
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
  # Build the code -> rule-index map in one pass. Appending with
  # `targets[[code]] <- c(targets[[code]], i)` reallocated the whole vector per
  # rule, so a code carried by 10,450 rules paid ~55M element copies.
  id_index <- setNames(seq_along(ids), ids)
  codes_per_rule <- lapply(bundle$rules, function(r) unlist(r$reporting_codes, use.names = FALSE))
  flat_codes <- unlist(codes_per_rule, use.names = FALSE)
  targets <- if (length(flat_codes))
    split(rep(seq_along(bundle$rules), lengths(codes_per_rule)), flat_codes) else list()
  action_targets <- split(seq_along(bundle$rules),vapply(bundle$rules,`[[`,character(1),'action_id'))
  rule_scopes <- lapply(bundle$rules, `[[`, 'scope')
  decisions <- list()
  # Combine a condition set in one call instead of re-wrapping per edge. The
  # incremental form appended with c(old$args, list(cond)), rebuilding the whole
  # argument list every time: one aluminium rule reached 75,656 arguments and the
  # pass cost 1.9e12 pointer copies, about 3.5 hours for a single revision. These
  # forms are structurally identical to the incremental ones -- a lone condition
  # stays unwrapped, a matching operator extends its arguments -- so only the
  # number of intermediate copies changes.
  combine_conditions <- function(old, op, conds) {
    if (!length(conds)) return(old)
    if (is.null(old)) return(if (length(conds) == 1L) conds[[1]] else list(op = op, args = conds))
    if (identical(old$op, op)) return(list(op = op, args = c(old$args, conds)))
    list(op = op, args = c(list(old), conds))
  }
  acc_target <- integer(0); acc_kind <- character(0)
  acc_cond <- list(); acc_src <- list(); nacc <- 0L
  for (edge in relations) {
    if (!edge$effect %in% c('suppress','require_predicate','suppress_by_reporting_codes') ||
        (edge$effect == 'suppress' && !edge$when_rule_applies %in% ids) ||
        (edge$effect == 'require_predicate' && is.null(edge$predicate)) ||
        !length(edge$source_ids) || !all(unlist(edge$source_ids) %in% source_ids) ||
        (as.integer(length(edge$target_reporting_codes)>0L)+as.integer(length(edge$target_action_ids)>0L)!=1L) ||
        (length(edge$target_action_ids)&&any(!vapply(edge$target_action_ids,function(id)
          is.character(id)&&length(id)==1L&&nzchar(id),logical(1)))) ||
        (!is.null(edge$target_rule_ids) && (!length(edge$target_rule_ids) || !all(unlist(edge$target_rule_ids)%in%ids))) ||
        (!is.null(edge$target_authority) && (!is.character(edge$target_authority)||length(edge$target_authority)!=1L||
          is.na(edge$target_authority)||!nzchar(edge$target_authority))) ||
        (!is.null(edge$trigger_test) && !edge$trigger_test %in% c('positive_duty','applicability')) ||
        (!is.null(edge$preserve_reporting_only)&&(!is.logical(edge$preserve_reporting_only)||
          length(edge$preserve_reporting_only)!=1L||is.na(edge$preserve_reporting_only)||
          !edge$effect %in% c('suppress','suppress_by_reporting_codes'))) ||
        (edge$effect=='suppress_by_reporting_codes' && (!length(edge$trigger_reporting_codes) ||
          (!is.null(edge$trigger_test) && !edge$trigger_test %in% c('positive_duty','applicability')))))
      stop('Invalid action relation: ', edge$id)
    if(!is.null(edge$source_window)) {
      w <- edge$source_window
      lower <- .shipment_time(w$from);upper <- .shipment_time(w$until)
      start <- .shipment_time(bundle$valid_from);end <- .shipment_time(bundle$valid_until)
      if(anyNA(c(lower,upper,start,end))||lower>=upper)stop('Invalid relation source window: ',edge$id)
      if(end<=lower||start>=upper)next
      if(start<lower||end>upper)stop('Source-windowed relation requires exact bundle tiling: ',edge$id)
    }
    trigger_ids <- character(0); trigger_ix <- integer(0)
    if(edge$effect=='suppress_by_reporting_codes') {
      trigger_ix <- sort(unique(unlist(targets[unlist(edge$trigger_reporting_codes)])))
      # Same contract check over the whole trigger set; only the accumulation
      # changed. Growing trigger_ids with c() per rule was quadratic, and a
      # single code-level relation can legitimately name 70,424 trigger rules.
      for(j in trigger_ix)
        if(length(setdiff(unlist(bundle$rules[[j]]$reporting_codes),unlist(edge$trigger_reporting_codes))))
          stop('Mixed trigger reporting codes: ',bundle$rules[[j]]$id)
      trigger_ids <- ids[trigger_ix]
    }
    target_ix <- if(length(edge$target_action_ids))unlist(action_targets[unlist(edge$target_action_ids)]) else
      unlist(targets[unlist(edge$target_reporting_codes)])
    # A trigger that cannot share a product, origin or interval with the target
    # can never fire. resolve_shipment_duties.R returns amount 0 and state
    # not_applicable for an out-of-scope rule, so such a disjunct is always
    # FALSE and contributes nothing to the determination. overlap() only
    # reports FALSE when disjointness is provable, so pruning on it removes
    # dead terms and never a live one.
    trigger_scope <- if (identical(edge$effect,'suppress'))
      rule_scopes[[ id_index[[edge$when_rule_applies]] ]] else NULL
    # Invert the trigger set by product once per relation so a target tests
    # only the triggers that could possibly reach it, instead of all of them.
    # overlap() stays the sole authority on liveness -- this only narrows the
    # candidates it is asked about. It can exclude nothing live: overlap()
    # clears the product dimension exactly when the trigger lists no exact
    # product (trig_universal), the target lists none, the target carries
    # prefixes, or the two share a product (trig_by_product).
    trig_hts <- lapply(trigger_ix,function(j)unlist(rule_scopes[[j]]$hts_exact,use.names=FALSE))
    trig_universal <- trigger_ix[lengths(trig_hts)==0L]
    trig_by_product <- if(length(trigger_ix)&&sum(lengths(trig_hts)))
      split(rep(trigger_ix,lengths(trig_hts)),unlist(trig_hts,use.names=FALSE)) else list()
    for (i in sort(unique(target_ix))) {
      target <- bundle$rules[[i]]
      if(!is.null(edge$target_authority)&&!identical(target$authority,edge$target_authority))next
      if(!is.null(edge$target_rule_ids) && !target$id %in% unlist(edge$target_rule_ids)) next
      matches <- intersect(unlist(target$reporting_codes), unlist(edge$target_reporting_codes))
      if (!length(matches)&&!length(edge$target_action_ids)) next
      if(isTRUE(edge$preserve_reporting_only)&&isTRUE(target$reporting_only)) {
        decisions[[length(decisions)+1L]]<-list(relation_id=edge$id,effect='reporting_obligation_retained',rule_id=target$id,source_ids=edge$source_ids)
        next
      }
      # A rule mixing independent headings must first be split into actions.
      if (length(edge$target_reporting_codes)&&length(setdiff(unlist(target$reporting_codes), matches))) stop('Mixed action reporting codes: ', target$id)
      if (edge$effect == 'suppress' && identical(target$id, edge$when_rule_applies)) stop('Self-suppressing action: ', target$id)
      if (edge$effect %in% c('suppress','suppress_by_reporting_codes')) {
        if(edge$effect=='suppress') {
          if(!overlap(trigger_scope, target$scope)) next
          condition <- if(identical(edge$trigger_test,'positive_duty'))
            list(op='gt',args=list(list(rule_amount=edge$when_rule_applies),list(value=0))) else list(rule_applies = edge$when_rule_applies)
        } else {
          if(target$id %in% trigger_ids) stop('Self-suppressing reporting relation: ',edge$id)
          if(!length(trigger_ids)) next # no invented trigger; coverage remains independently required
          t_hts <- unlist(target$scope$hts_exact,use.names=FALSE)
          cand <- if(!length(t_hts)||length(target$scope$hts_prefixes)) trigger_ix else
            sort(unique(c(trig_universal,
              unlist(trig_by_product[intersect(t_hts,names(trig_by_product))],use.names=FALSE))))
          live <- cand[vapply(cand,function(j)overlap(rule_scopes[[j]],target$scope),logical(1))]
          if(!length(live)) next
          condition <- list(op='or',args=lapply(ids[live],function(id)
            if(identical(edge$trigger_test,'positive_duty'))
              list(op='gt',args=list(list(rule_amount=id),list(value=0))) else list(rule_applies=id)))
        }
        nacc <- nacc+1L; acc_kind[[nacc]] <- 'suppressed_when'
      } else {
        condition <- edge$predicate
        nacc <- nacc+1L; acc_kind[[nacc]] <- 'when'
      }
      acc_target[[nacc]] <- i; acc_cond[[nacc]] <- condition
      acc_src[[nacc]] <- unlist(edge$source_ids)
      decision <- list(relation_id = edge$id, rule_id = target$id,
        when_rule_applies = edge$when_rule_applies, effect = edge$effect,
        reporting_codes = as.list(matches), source_ids = edge$source_ids)
      if(!is.null(edge$target_action_ids))decision$target_action_ids <- edge$target_action_ids
      if(!is.null(edge$source_window))decision$source_window <- edge$source_window
      decisions[[length(decisions)+1L]] <- decision
    }
  }
  # Apply the collected conditions once per target. Ordering matches the
  # incremental form exactly: conditions were recorded in relation order and,
  # within a relation, in ascending target index, and split() preserves that
  # order inside each group -- so every argument list is identical to what the
  # per-edge rewrite produced. The union of source ids is order-independent.
  if (nacc) {
    for (sel in split(seq_len(nacc), acc_target)) {
      i <- acc_target[[sel[[1L]]]]; target <- bundle$rules[[i]]
      sup <- sel[acc_kind[sel] == 'suppressed_when']
      whn <- sel[acc_kind[sel] == 'when']
      if (length(sup)) target$suppressed_when <- combine_conditions(target$suppressed_when, 'or', acc_cond[sup])
      if (length(whn)) target$when <- combine_conditions(target$when, 'and', acc_cond[whn])
      target$source_ids <- as.list(sort(unique(c(unlist(target$source_ids), unlist(acc_src[sel])))))
      bundle$rules[[i]] <- target
    }
  }
  # Relations can introduce predicates after initial rule binding. They use
  # the same source-backed fact identities and reporting lookup as rule bodies.
  bundle$rules <- lapply(bundle$rules,rewrite_rule)
  # Explicit, source-backed cross-authority claim effects. Recognize only a
  # registered claim whose candidate rules all belong to the stated authority;
  # a claim-name prefix alone is not evidence of its meaning.
  passthrough <- merge_by_id(unlist(lapply(fragments,`[[`,'unchanged_claims'),recursive=FALSE),'claim relation')
  for(edge in passthrough) {
    if(!is.null(edge$effect) && !edge$effect %in% c('unchanged','reevaluate')) stop('Invalid claim relation effect')
    if(length(edge$target_authorities)) {
      if(length(edge$target_rule_ids)||!length(edge$claim_ids)) stop('Authority claim relation requires explicit claims')
      edge$target_rule_ids<-as.list(ids[vapply(bundle$rules,function(r) r$authority %in% unlist(edge$target_authorities),logical(1))])
      if(length(edge$target_base_treatments)) {
        if(!identical(unlist(edge$target_authorities),'base') ||
           !all(unlist(edge$target_base_treatments) %in% c('column1_general','column2')))
          stop('Invalid ordinary-base claim relation')
        edge$target_rule_ids<-as.list(ids[vapply(bundle$rules,function(r)
          identical(r$authority,'base') && length(r$base_treatment)==1L &&
          r$base_treatment %in% unlist(edge$target_base_treatments),logical(1))])
      }
      # An independent fragment need not contain the other authorities yet.
      if(!length(edge$target_rule_ids)) next
    }
    if(!length(edge$target_rule_ids)||!all(unlist(edge$target_rule_ids)%in%ids)||
       !length(edge$source_ids)||!all(unlist(edge$source_ids)%in%source_ids)||
       is.null(edge$claim_authority)) stop('Invalid unchanged-claim relation')
    for(i in seq_along(bundle$claim_definitions)) {
      claim<-bundle$claim_definitions[[i]];candidates<-unlist(claim$candidate_rule_ids)
      if(length(edge$claim_ids) && !claim$id %in% unlist(edge$claim_ids)) next
      if(!length(candidates)) next
      crules<-bundle$rules[match(candidates,ids)]
      if(anyNA(match(candidates,ids)) || !all(vapply(crules,function(r) identical(r$authority,edge$claim_authority),logical(1)))) next
      if(length(edge$candidate_required_fields) && !all(vapply(crules,function(r)
        all(vapply(unlist(edge$candidate_required_fields),function(k) is.character(r[[k]])&&length(r[[k]])==1&&nzchar(r[[k]]),logical(1))),logical(1)))) next
      claim$rule_ids<-as.list(sort(unique(c(unlist(claim$rule_ids),unlist(edge$target_rule_ids)))))
      claim$source_ids<-as.list(sort(unique(c(unlist(claim$source_ids),unlist(edge$source_ids)))))
      bundle$claim_definitions[[i]]<-claim
      decisions[[length(decisions)+1L]]<-list(relation_id=edge$id,claim_id=claim$id,
        effect=if(identical(edge$effect,'reevaluate')) 'claim_reevaluates_action_dependencies' else 'claim_leaves_liability_unchanged',rule_ids=edge$target_rule_ids,source_ids=edge$source_ids)
    }
  }
  # A source can require another election as part of a requested treatment.
  # Compile the directed claim closure into ordinary AST; interpreters need
  # no program-specific constants and the caller's original elections survive.
  implications<-merge_by_id(unlist(lapply(fragments,`[[`,'claim_implications'),recursive=FALSE),'claim implication')
  if(length(implications)) {
    claim_ids<-vapply(bundle$claim_definitions,`[[`,character(1),'id')
    for(edge in implications) {
      scalar<-function(x)is.character(x)&&length(x)==1L&&!is.na(x)&&nzchar(x)
      if(!scalar(edge$claim_id)||!scalar(edge$implies)||edge$claim_id==edge$implies||
         !all(c(edge$claim_id,edge$implies)%in%claim_ids)||!length(edge$source_ids)||
         !all(unlist(edge$source_ids)%in%known_sources))stop('Unverified claim implication: ',edge$id)
      if(!is.null(edge$activation_rule_ids)&&any(!unlist(edge$activation_rule_ids)%in%ids))
        stop('Unknown claim activation rule: ',edge$id)
    }
    ancestors<-function(id,visiting=character()) {
      if(id%in%visiting)stop('Cyclic claim implication: ',id)
      direct<-vapply(Filter(function(e)identical(e$implies,id),implications),`[[`,character(1),'claim_id')
      sort(unique(c(direct,unlist(lapply(direct,ancestors,visiting=c(visiting,id)),use.names=FALSE))))
    }
    closure<-setNames(lapply(claim_ids,ancestors),claim_ids)
    implied_claim<-function(id) {
      args<-list(list(claim=id))
      for(edge in Filter(function(e)identical(e$implies,id),implications)) {
        used_sources<<-union(used_sources,unlist(edge$source_ids,use.names=FALSE))
        trigger<-implied_claim(edge$claim_id)
        if(!is.null(edge$activation_rule_ids)) {
          gates<-lapply(sort(unique(unlist(edge$activation_rule_ids))),function(rid)list(rule_applies=rid))
          gate<-if(!length(gates))list(value=FALSE) else if(length(gates)==1L)gates[[1]] else list(op='or',args=gates)
          trigger<-list(op='and',args=list(trigger,gate))
        }
        args[[length(args)+1L]]<-trigger
      }
      if(length(args)==1L)args[[1]] else list(op='or',args=args)
    }
    expand_claims<-function(node) {
      if(!is.list(node))return(node)
      if(length(node)==1L&&!is.null(node$claim)&&length(closure[[node$claim]])) {
        return(implied_claim(node$claim))
      }
      lapply(node,expand_claims)
    }
    bundle$rules<-lapply(bundle$rules,function(r) {
      used_sources<<-character()
      for(k in c('when','suppressed_when','formula','input_constraints'))if(!is.null(r[[k]]))r[[k]]<-expand_claims(r[[k]])
      r$source_ids<-as.list(sort(unique(c(unlist(r$source_ids),used_sources))))
      r
    })
    bundle$claim_implication_decisions<-implications
  }
  # Adding actions deliberately invalidates incomplete existing inventories.
  # Only a separate legal review may attest all-action authority coverage.
  bundle$coverage <- c(bundle$coverage, unlist(lapply(fragments, `[[`, 'coverage'), recursive = FALSE))
  bundle$relation_decisions <- decisions
  for(fragment in fragments) if(!is.null(fragment$grant_snapshot)) {
    old<-bundle$evidence_dependencies$section232_grants
    if(!is.null(old) && !identical(.shipment_canonical(old),.shipment_canonical(fragment$grant_snapshot)))
      stop('Mixed Commerce grant evidence snapshots')
    bundle$evidence_dependencies$section232_grants<-fragment$grant_snapshot
  }
  features<-sort(unique(unlist(lapply(fragments,`[[`,'required_compiler_features'),use.names=FALSE)))
  bundle$compiler <- list(id = if(length(features))'sail.shipment-rule-composer/v2' else 'sail.shipment-rule-composer/v1',
    fragments = as.list(sort(unique(vapply(fragments,`[[`,character(1),'id')))))
  if(length(features))bundle$compiler$features<-as.list(features)
  bundle
}
