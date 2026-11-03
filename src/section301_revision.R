# Revision-bound China Section 301 extraction and evaluation. The PDF tables
# supply scope; the same revision's HTS heading supplies the rate expression.
# Never use a global HTS8 list or choose a maximum to resolve legal conflicts.

if (!exists('.shipment_time', mode='function')) source(here::here('src/resolve_shipment_duties.R'))

# The audited build window is stated once, in the build contract. Repeating its
# end instant as a literal is what lets a horizon extension leave a compiler
# behind, emitting an interval whose end precedes its start.
.s301_audit_window <- function() {
  if(!exists('SHIPMENT_BUILD_SPEC')) source(here::here('src/shipment_build.R'))
  get('SHIPMENT_BUILD_SPEC')
}

load_s301_revision_source <- function(revision_id, root = here::here(), download = TRUE) {
  if (!grepl('^202[56]_(basic|rev_[0-9]+)$', revision_id))
    stop('Section 301 source extraction requires an identified 2025/2026 revision')
  pdf <- file.path(root, 'data/us_notes', paste0('chapter99_', revision_id, '.pdf'))
  hts <- file.path(root, 'data/hts_archives', paste0('hts_', revision_id, '.json'))
  if (!file.exists(pdf) && download) {
    dir.create(dirname(pdf), recursive=TRUE, showWarnings=FALSE)
    url <- build_chapter99_url(build_release_name(revision_id))
    temp <- tempfile(fileext='.pdf')
    on.exit(unlink(temp), add=TRUE)
    utils::download.file(url, temp, mode='wb', quiet=TRUE)
    if (!identical(rawToChar(readBin(temp,'raw',4)), '%PDF')) stop('Not a Chapter 99 PDF: ', url)
    if (!file.copy(temp,pdf)) stop('Could not retain Chapter 99 source')
  }
  if (!file.exists(pdf) || !file.exists(hts)) stop('Missing revision-bound Section 301 PDF/HTS source: ', revision_id)
  script <- file.path(root, 'src/section301_sources.py')
  cache <- file.path(root, 'data/processed/s301_sources', paste0(revision_id,'.json'))
  hash <- function(file) digest::digest(file=file,algo='sha256')
  valid <- function(x) identical(x$contract_version,'sail.section301-extraction/v1') &&
    identical(x$revision,revision_id) && identical(x$extractor_sha256,hash(script)) &&
    identical(x$sources[[1]]$sha256,hash(pdf)) && identical(x$sources[[2]]$sha256,hash(hts)) &&
    all(vapply(x$additional_sources,function(s) file.exists(s$path) && identical(s$sha256,hash(s$path)) &&
      (is.null(s$metadata_path) || (file.exists(s$metadata_path) && identical(s$metadata_sha256,hash(s$metadata_path)))),logical(1)))
  x <- if(file.exists(cache)) tryCatch(jsonlite::fromJSON(cache,simplifyVector=FALSE),error=function(e) NULL) else NULL
  if(is.null(x) || !valid(x)) {
    temp <- tempfile(fileext='.json')
    on.exit(unlink(temp),add=TRUE)
    status <- system2('python3',c(shQuote(script),'--pdf',shQuote(pdf),'--hts',shQuote(hts),
      '--revision',shQuote(revision_id),'--output',shQuote(temp)))
    if(status!=0L) stop('Section 301 source extraction failed; refusing legacy-list fallback')
    x <- jsonlite::fromJSON(temp,simplifyVector=FALSE)
    if(!valid(x)) stop('Section 301 extraction source/hash mismatch')
    dir.create(dirname(cache),recursive=TRUE,showWarnings=FALSE)
    if(!file.copy(temp,cache,overwrite=TRUE)) stop('Could not retain source extraction')
  }
  x
}

s301_revision_matches <- function(extraction, products, entry_at, country='5700') {
  if(!exists('.shipment_time',mode='function')) source(here::here('src/resolve_shipment_duties.R'))
  at <- .shipment_time(entry_at)
  if(is.na(at)) stop('An exact entry timestamp is required')
  rows <- list()
  products <- unique(as.character(products))
  if(any(!grepl('^[0-9]{10}$',products))) stop('Products must be valid HTS10 identifiers')
  by_prefix <- split(products,substr(products,1,8))
  for(action in extraction$actions) {
    if(!is.null(action$country_scope) && action$country_scope!='all' && action$country_scope!=country) next
    if(!is.null(action$valid_from) && at < .shipment_time(action$valid_from)) next
    if(!is.null(action$valid_until) && at >= .shipment_time(action$valid_until)) next
    for(scope in action$scopes) {
      inc <- unlist(scope$includes); exc <- unlist(scope$excludes)
      if(any(!nchar(c(inc,exc)) %in% c(8L,10L))) stop('Invalid Section 301 scope grain')
      included <- unique(c(unlist(by_prefix[inc[nchar(inc)==8]],use.names=FALSE),
        intersect(products,inc[nchar(inc)==10])))
      included <- included[!included %in% exc & !substr(included,1,8) %in% exc]
      if(!length(included)) next
      rows[[length(rows)+1L]] <- data.frame(hts10=included,
        ch99_code=action$reporting_code, rate=action$rate,
        program=action$program,country_scope=action$country_scope,
        condition_text=if(is.null(scope$condition_text)) NA_character_ else scope$condition_text,
        source_locator=scope$locator, source_text_sha256=scope$source_text_sha256,
        pdf_sha256=extraction$sources[[1]]$sha256, hts_sha256=extraction$sources[[2]]$sha256,
        valid_from=if(is.null(action$valid_from)) NA_character_ else action$valid_from,
        valid_until=if(is.null(action$valid_until)) NA_character_ else action$valid_until,
        stringsAsFactors=FALSE)
    }
  }
  empty <- data.frame(hts10=character(),ch99_code=character(),rate=numeric(),program=character(),country_scope=character(),condition_text=character(),
    source_locator=character(),source_text_sha256=character(),pdf_sha256=character(),hts_sha256=character(),
    valid_from=character(),valid_until=character())
  if(!length(rows)) return(empty)
  out <- unique(do.call(rbind,rows))
  # Multiple rows within a single heading are OR alternatives, not cumulative
  # duties. Distinct headings require a legally extracted relationship; rate
  # magnitude is never a tie-breaker.
  by_product <- split(out$ch99_code,paste(out$hts10,out$program))
  bad <- names(Filter(function(x) length(unique(x))>1,by_product))
  if(length(bad)) stop('Unresolved overlapping Section 301 actions: ',paste(head(bad,20),collapse=', '))
  out
}

s301_revision_lookup <- function(matches) {
  if(length(unique(matches$program))>1) stop('Distinct Section 301 investigations require separate projections')
  if(!nrow(matches)) return(data.frame(hts10=character(),blanket_301=numeric(),src_301=character(),
    s301_scope_requires_inputs=logical(),modeled_s301_scope_share=numeric()))
  rows <- lapply(split(matches,matches$hts10),function(x) {
    if(length(unique(x$rate))!=1) stop('Conflicting rates for Section 301 action')
    data.frame(hts10=x$hts10[1],blanket_301=x$rate[1],src_301=x$ch99_code[1],
      s301_scope_requires_inputs=all(!is.na(x$condition_text)),modeled_s301_scope_share=1)
  })
  do.call(rbind,rows)
}

# Executable source fragment for the shared R/TypeScript interpreter. This is
# emitted by the ordinary normalized build, not maintained as copied constants.
# It deliberately does not attest complete Section 301 coverage (other actions
# and unlisted claim effects must be composed separately).
compile_s301_revision_fragment <- function(extraction, products) {
  revision <- extraction$revision
  # A historical ruling or broad annex prefix cannot manufacture a current
  # statistical suffix. Reuse the native hierarchy's complete product inventory.
  source(here::here('src/shipment_build.R'))
  native<-load_shipment_base_source(revision)
  if(!identical(native$source$sha256,extraction$sources[[2]]$sha256))stop('Section301/native classification source mismatch')
  products<-sort(unique(as.character(products)))
  valid_products<-vapply(c(native$products,native$special_classifications),`[[`,character(1),'hts10')
  if(any(!products%in%valid_products))
    stop('Product is not valid in the identified Section301 source revision')
  source_ids <- paste0('USITC-',revision,c('-chapter99','-hts'))
  release <- build_release_name(revision)
  sources <- lapply(seq_along(source_ids),function(i) list(id=source_ids[i],status='verified',
    sha256=extraction$sources[[i]]$sha256,
    url=paste0('https://hts.usitc.gov/reststop/',if(i==1) 'file?release=' else 'exportList?release=',
      release,if(i==1) '&filename=Chapter%2099' else '&exportFormat=JSON'),
    citation=paste0('USITC ',revision,': Chapter 99 notes 20/31 and headings 9903.88, 9903.91, 9903.92.10. ',
      'Charge scope only; see the rule source locator and description.')))
  artifacts <- lapply(seq_along(source_ids),function(i)
    list(source_id=source_ids[i],path=extraction$sources[[i]]$path,sha256=extraction$sources[[i]]$sha256))
  for(s in extraction$additional_sources) {
    sources[[length(sources)+1L]] <- list(id=s$id,status='verified',sha256=s$sha256,url=s$url,citation=s$citation)
    artifacts[[length(artifacts)+1L]] <- list(source_id=s$id,path=s$path,sha256=s$sha256)
    source_ids <- c(source_ids,s$id)
  }
  input<-tempfile(fileext='.json');output<-tempfile(fileext='.json')
  on.exit(unlink(c(input,output)),add=TRUE)
  jsonlite::write_json(extraction,input,auto_unbox=TRUE,null='null',digits=NA)
  status<-system2('python3',c(shQuote(here::here('src/section301_chapter98.py')),shQuote(input),shQuote(output)))
  if(status!=0L) stop('Source-defined Section 301 Chapter 98 compilation failed')
  chapter98<-jsonlite::fromJSON(output,simplifyVector=FALSE)
  chapter98_ids<-list()
  rules <- list(); facts <- list(customs_value=list(type='number',minimum=0,unit='USD',
    label='Customs value (USD)',source_ids=as.list(source_ids)))
  facts<-c(facts,chapter98$fact_definitions)
  for(action in extraction$actions) {
    one <- extraction; one$actions <- list(action)
    at <- if(is.null(action$valid_from)) '2025-01-01T00:00:00-05:00' else action$valid_from
    matched <- s301_revision_matches(one,products,at)
    if(!nrow(matched)) next
    if(any(duplicated(matched$hts10))) stop('Overlapping alternatives within Section 301 heading')
    groups <- split(matched,ifelse(is.na(matched$condition_text),'unconditional',matched$source_text_sha256))
    for(key in names(groups)) {
      group <- groups[[key]]
      id <- paste0('s301_',gsub('[.]','',action$reporting_code),'_',key)
      scope <- list(hts_exact=as.list(sort(group$hts10)),countries=list('5700'))
      if(action$country_scope=='all') scope$countries <- NULL
      if(!is.null(action$valid_from)) scope$from <- action$valid_from
      if(!is.null(action$valid_until)) scope$until <- action$valid_until
      rule <- list(id=id,action_id=paste0('s301_',gsub('[.]','',action$reporting_code)),
        authority='section_301',kind='duty',verification='verified',scope=scope,
        formula=list(op='multiply',args=list(list(fact='customs_value'),list(value=action$rate))),
        reporting_codes=list(action$reporting_code),source_ids=as.list(source_ids),
        legal_locator=action$locator,source_scope_locators=as.list(unique(group$source_locator)))
      if(key!='unconditional') {
        name <- paste0('matches_',id)
        rule$when <- list(fact=name)
        facts[[name]] <- list(type='boolean',label=paste0('Product meets ',action$reporting_code,' description'),
          description=group$condition_text[1],source_ids=as.list(source_ids))
      }
      valuation<-chapter98$valuations[[action$reporting_code]]
      if(!is.null(valuation)) {
        condition<-rule$when %||% list(value=TRUE)
        exempt<-rule;exempt$id<-paste0(rule$id,'_chapter98')
        exempt$when<-list(op='and',args=list(condition,valuation$exempt))
        exempt$formula<-list(value=0);exempt$reporting_codes<-list()
        exempt$legal_locator<-action$chapter98$locator
        exempt$chapter98_target_reporting_code<-action$reporting_code
        exempt$chapter98_clause_sha256<-action$chapter98$source_text_sha256
        exempt$input_constraints<-valuation$constraints
        rule$when<-list(op='and',args=list(condition,list(op='not',args=list(valuation$exempt))))
        rule$formula<-list(op='multiply',args=list(valuation$basis,list(value=action$rate)))
        rule$input_constraints<-valuation$constraints
        rule$valuation_locator<-action$chapter98$locator
        rule$chapter98_target_reporting_code<-action$reporting_code
        rule$chapter98_clause_sha256<-action$chapter98$source_text_sha256
        rules[[length(rules)+1L]]<-exempt
        chapter98_ids<-c(chapter98_ids,list(rule$id,exempt$id))
      }
      rules[[length(rules)+1L]] <- rule
      if(!is.null(action$start_time_conflict)) {
        gap <- rule
        gap$id <- paste0(rule$id,'_unresolved_time_zone')
        gap$verification <- 'unresolved_source'
        gap$scope$from <- action$start_time_conflict$unresolved_from
        gap$scope$until <- action$start_time_conflict$unresolved_until
        gap$source_discrepancy <- action$start_time_conflict
        rules[[length(rules)+1L]] <- gap
      }
    }
  }
  exclusions <- compile_s301_exclusion_rules(extraction,products,source_ids[1:2])
  rules <- c(rules,exclusions$rules)
  facts <- c(facts,exclusions$fact_definitions)
  # The note names the charges removed; other compiled Section 301 actions are
  # retained. Other authorities need their own explicit reviewed claim effects.
  claim_definitions <- lapply(exclusions$claim_definitions,function(c) {
    c$rule_ids <- lapply(rules,`[[`,'id'); c
  })
  if(length(chapter98_ids)) claim_definitions<-c(claim_definitions,list(list(id='CHAPTER_98',
    label='Chapter 98',source_ids=as.list(source_ids[1:2]),
    candidate_rule_ids=chapter98_ids,
    rule_ids=c(chapter98_ids,lapply(exclusions$rules,`[[`,'id')))))
  fragment<-list(contract_version='sail.shipment-rule-fragment/v1',id=paste0('s301_china_',revision),
    compiler_sha256=digest::digest(file=here::here('src/section301_revision.R'),algo='sha256'),
    compiler_dependencies=setNames(lapply(c('src/section301_chapter98.py','src/chapter98_rules.py','src/section301_sources.py',
      'src/shipment_build.R','src/shipment_base_sources.py','resources/shipment_rules/build_contract.json'),
      function(p) digest::digest(file=here::here(p),algo='sha256')),
      c('src/section301_chapter98.py','src/chapter98_rules.py','src/section301_sources.py','src/shipment_build.R','src/shipment_base_sources.py','resources/shipment_rules/build_contract.json')),
    supported_from=.s301_audit_window()$audit_from,supported_until=.s301_audit_window()$audit_until,
    sources=sources,source_artifacts=artifacts,
    rules=rules,fact_definitions=facts,claim_definitions=claim_definitions,
    coverage=list(),relations=exclusions$relations,
    limitations=extraction$limitations)
  source(here::here('src/ftz_valuation.R'))
  compile_current_npf_context(fragment,'section301_pf_admission_classification_and_rate_history',
    'section301_ftz_chapter98_admission_and_entry_treatment')
}

# Compile named exclusion effects from independently extracted product-code and
# grant windows. No aggregate rate or utilization share enters these rules.
compile_s301_exclusion_rules <- function(extraction, products, revision_source_ids) {
  if(is.null(extraction$exclusions)) stop('Missing source-backed Section 301 exclusion chronology')
  rules<-list();facts<-list();relations<-list();claims<-list()
  canonical_json <- function(x) as.character(jsonlite::toJSON(.shipment_canonical(x),auto_unbox=TRUE,null='null',digits=NA))
  instant <- function(x, fallback) if(is.null(x)) .shipment_time(fallback) else .shipment_time(x)
  iso <- function(t) format(as.POSIXct(t,origin='1970-01-01',tz='UTC'),'%Y-%m-%dT%H:%M:%SZ',tz='UTC')
  for(record in extraction$exclusions$records) {
    claim <- paste0('section301:',record$reporting_code)
    stem <- paste0('s301_exclusion_',gsub('[^a-z0-9]','_',tolower(record$locator)))
    predicate <- list(claim=claim)
    src <- sort(unique(c(revision_source_ids,unlist(record$source_ids),unlist(lapply(record$amendments,`[[`,'source_id')))))
    if(!is.null(record$condition_text)) {
      name <- paste0('matches_',stem)
      facts[[name]] <- list(type='boolean',label=paste0('Meets ',record$locator,' product description'),
        description=record$condition_text,source_ids=as.list(src))
      predicate <- list(op='and',args=list(predicate,list(fact=name)))
    }
    for(b in seq_along(record$bindings)) {
      binding <- record$bindings[[b]]
      matched <- sort(unique(unlist(lapply(binding$codes,function(code) {
        if(!nchar(code) %in% c(8L,10L)) stop('Invalid exclusion scope grain')
        products[startsWith(products,code)]
      }))))
      if(!length(matched)) next
      for(w in seq_along(extraction$exclusions$windows[[record$reporting_code]])) {
        window <- extraction$exclusions$windows[[record$reporting_code]][[w]]
        audited <- .s301_audit_window()
        start <- max(instant(binding$valid_from,audited$audit_from),
          .shipment_time(window$possible_from),.shipment_time(audited$audit_from))
        end <- min(instant(binding$valid_until,audited$audit_until),
          .shipment_time(window$possible_until),.shipment_time(audited$audit_until))
        if(start>=end) next
        known_start <- max(start,.shipment_time(window$valid_from))
        known_end <- min(end,.shipment_time(window$valid_until))
        for(amendment in record$amendments) {
          if(!is.null(binding$valid_from) && .shipment_time(binding$valid_from)>=.shipment_time(amendment$effective_day))
            known_start <- max(known_start,.shipment_time(amendment$entry_window$valid_from))
        }
        # Boundaries preserve both the published minute/offset and the heading's
        # calendar-day wording. A requested claim remains unresolved there.
        cuts <- sort(unique(pmax(start,pmin(end,c(start,known_start,known_end,end)))))
        ranges <- lapply(seq_len(length(cuts)-1L),function(k)
          c(cuts[k],cuts[k+1L],as.numeric(cuts[k]>=known_start && cuts[k+1L]<=known_end)))
        for(k in seq_along(ranges)) {
          range<-ranges[[k]];if(range[1]>=range[2]) next
          id<-paste0(stem,'_b',b,'_w',w,'_',k)
          when<-predicate
          if(range[3]==0) when<-list(op='and',args=list(predicate,
            list(unresolved_source=paste0('exclusion_entry_boundary:',record$locator))))
          sources<-as.list(sort(unique(c(src,window$source_id))))
          rules[[length(rules)+1L]]<-list(id=id,action_id=stem,authority='section_301',kind='duty',
            verification='verified',scope=list(hts_exact=as.list(matched),countries=list('5700'),
              from=iso(range[1]),until=iso(range[2])),when=when,formula=list(value=0),
            reporting_codes=list(record$reporting_code),source_ids=sources,
            legal_locator=record$locator,role='exclusion',claim_id=claim,
            target_reporting_codes=record$target_reporting_codes,source_text_sha256=record$source_text_sha256)
          relations[[length(relations)+1L]]<-list(id=paste0(id,'_effect'),effect='suppress',
            when_rule_applies=id,target_reporting_codes=record$target_reporting_codes,source_ids=sources)
          old<-claims[[claim]]
          claims[[claim]]<-list(id=claim,label=paste0('Section 301 exclusion ',record$reporting_code),
            source_ids=as.list(sort(unique(c(unlist(old$source_ids),unlist(sources))))),
            candidate_rule_ids=c(old$candidate_rule_ids,list(id)),rule_ids=list())
        }
      }
    }
  }
  # Several descriptions may be alternatives for one code. Evaluate their OR
  # once: one established exclusion must not demand facts for every alternative.
  grouped <- list()
  for(i in seq_along(rules)) for(hts in unlist(rules[[i]]$scope$hts_exact)) {
    key<-paste(hts,rules[[i]]$reporting_codes[[1]],paste(unlist(relations[[i]]$target_reporting_codes),collapse=','),sep='|')
    grouped[[key]]<-c(grouped[[key]],i)
  }
  merged<-list();edges<-list();claims<-list()
  for(key in sort(names(grouped))) {
    idx<-grouped[[key]];rs<-rules[idx]
    starts<-vapply(rs,function(r) .shipment_time(r$scope$from),numeric(1))
    ends<-vapply(rs,function(r) .shipment_time(r$scope$until),numeric(1))
    cuts<-sort(unique(c(starts,ends)))
    for(k in seq_len(length(cuts)-1L)) {
      active<-which(starts<=cuts[k] & ends>=cuts[k+1L]);if(!length(active)) next
      selected<-rs[active];first<-selected[[1]]
      predicates<-lapply(selected,`[[`,'when')
      signatures<-vapply(predicates,canonical_json,character(1))
      predicates<-predicates[match(sort(unique(signatures)),signatures)]
      sources<-as.list(sort(unique(unlist(lapply(selected,`[[`,'source_ids')))))
      records<-lapply(selected,function(r) list(locator=r$legal_locator,sha256=r$source_text_sha256))
      signatures<-vapply(records,canonical_json,character(1))
      records<-records[match(sort(unique(signatures)),signatures)]
      id<-paste0('s301_exclusion_',digest::digest(paste(key,cuts[k],cuts[k+1L]),algo='sha256',serialize=FALSE))
      first$id<-id;first$action_id<-paste0('s301_exclusion_',gsub('[.]','',first$reporting_codes[[1]]))
      first$scope$hts_exact<-list(strsplit(key,'|',fixed=TRUE)[[1]][1])
      first$scope$from<-iso(cuts[k]);first$scope$until<-iso(cuts[k+1L])
      first$when<-if(length(predicates)==1) predicates[[1]] else list(op='or',args=predicates)
      first$source_ids<-sources;first$legal_locator<-paste(sort(unique(unlist(lapply(records,`[[`,'locator')))),collapse='; ')
      first$source_scope_records<-records;first$source_text_sha256<-NULL
      first$source_scope_sha256<-digest::digest(canonical_json(records),algo='sha256',serialize=FALSE)
      first$exclusion_claim_id<-paste0('section301:',first$reporting_codes[[1]])
      merged[[length(merged)+1L]]<-first
      edge<-relations[[idx[active[1]]]];edge$id<-paste0(id,'_effect');edge$when_rule_applies<-id;edge$source_ids<-sources
      edges[[length(edges)+1L]]<-edge
      claim<-paste0('section301:',first$reporting_codes[[1]]);old<-claims[[claim]]
      claims[[claim]]<-list(id=claim,label=paste0('Section 301 exclusion ',first$reporting_codes[[1]]),
        source_ids=as.list(sort(unique(c(unlist(old$source_ids),unlist(sources))))),
        candidate_rule_ids=c(old$candidate_rule_ids,list(id)),rule_ids=list())
    }
  }
  list(rules=merged,fact_definitions=facts,relations=edges,claim_definitions=unname(claims))
}

s301_exclusion_candidates <- function(extraction, products, entry_at) {
  at <- .shipment_time(entry_at)
  if(is.na(at) || is.null(extraction$exclusions)) stop('Missing exclusion chronology or entry time')
  rows<-list()
  charges<-s301_revision_matches(extraction,products,entry_at)
  for(record in extraction$exclusions$records) {
    windows<-extraction$exclusions$windows[[record$reporting_code]]
    in_window<-any(vapply(windows,function(w) at>=.shipment_time(w$possible_from) && at<.shipment_time(w$possible_until),logical(1)))
    if(!in_window) next
    for(binding in record$bindings) {
      if(!is.null(binding$valid_from) && at<.shipment_time(binding$valid_from)) next
      if(!is.null(binding$valid_until) && at>=.shipment_time(binding$valid_until)) next
      charged<-charges$hts10[charges$ch99_code %in% unlist(record$target_reporting_codes)]
      matched<-unique(unlist(lapply(binding$codes,function(code) charged[startsWith(charged,code)])))
      if(!length(matched)) next
      rows[[length(rows)+1L]]<-data.frame(hts10=matched,ch99_code=record$reporting_code,
        source_locator=record$locator,source_text_sha256=record$source_text_sha256,
        condition_text=if(is.null(record$condition_text)) NA_character_ else record$condition_text)
    }
  }
  if(!length(rows)) return(data.frame(hts10=character(),ch99_code=character(),source_locator=character(),
    source_text_sha256=character(),condition_text=character()))
  unique(do.call(rbind,rows))
}

# Normalized claim effects retain the executable condition and exactly which
# charge headings it suppresses, independently of aggregate exemption shares.
s301_claim_effects_table <- function(fragment, revision) {
  rows<-list()
  rules<-setNames(fragment$rules,vapply(fragment$rules,`[[`,character(1),'id'))
  for(edge in fragment$relations) {
    rule<-rules[[edge$when_rule_applies]]
    if(is.null(rule)) stop('Unknown exclusion relation rule')
    for(code in unlist(edge$target_reporting_codes)) rows[[length(rows)+1L]]<-data.frame(
      revision=revision,claim_id=paste0('section301:',rule$reporting_codes[[1]]),verification=rule$verification,
      rule_id=rule$id,authority=rule$authority,effect=edge$effect,target_reporting_code=code,
      hts10=unlist(rule$scope$hts_exact),country='5700',valid_from=rule$scope$from,valid_until=rule$scope$until,
      source_ids_json=as.character(jsonlite::toJSON(rule$source_ids,auto_unbox=FALSE)),
      condition_json=as.character(jsonlite::toJSON(rule$when,auto_unbox=TRUE,null='null')),
      source_locator=rule$legal_locator,source_scope_sha256=rule$source_scope_sha256,
      formula_json=as.character(jsonlite::toJSON(rule$formula,auto_unbox=TRUE,null='null')),
      input_constraints_json='[]')
  }
  for(rule in fragment$rules) {
    if(is.null(rule$chapter98_target_reporting_code)) next
    rows[[length(rows)+1L]]<-data.frame(revision=revision,claim_id='CHAPTER_98',verification=rule$verification,rule_id=rule$id,
      authority=rule$authority,effect='conditional_valuation',target_reporting_code=rule$chapter98_target_reporting_code,
      hts10=unlist(rule$scope$hts_exact),country=rule$scope$countries[[1]] %||% NA_character_,
      valid_from=rule$scope$from %||% fragment$supported_from,valid_until=rule$scope$until %||% fragment$supported_until,
      source_ids_json=as.character(jsonlite::toJSON(rule$source_ids,auto_unbox=FALSE)),
      condition_json=as.character(jsonlite::toJSON(rule$when,auto_unbox=TRUE,null='null')),
      source_locator=rule$valuation_locator %||% rule$legal_locator,source_scope_sha256=rule$chapter98_clause_sha256,
      formula_json=as.character(jsonlite::toJSON(rule$formula,auto_unbox=TRUE,null='null')),
      input_constraints_json=as.character(jsonlite::toJSON(rule$input_constraints,auto_unbox=TRUE,null='null')))
  }
  if(!length(rows)) return(data.frame(revision=character(),claim_id=character(),verification=character(),rule_id=character(),
    authority=character(),effect=character(),target_reporting_code=character(),hts10=character(),country=character(),
    valid_from=character(),valid_until=character(),source_ids_json=character(),condition_json=character(),
    source_locator=character(),source_scope_sha256=character(),formula_json=character(),input_constraints_json=character()))
  do.call(rbind,rows)
}
