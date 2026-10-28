# Normal-build shipment contract. Raw source extraction, executable interpretation
# and aggregate calculations have separate inputs. Never consume an economic rate
# or modeled share when constructing a shipment rule.
source(here::here('src/compile_shipment_rules.R'))
source(here::here('src/shipment_duty_expression.R'))
source(here::here('src/ftz_valuation.R'))

if(!exists('.shipment_base_hot',inherits=FALSE)).shipment_base_hot <- new.env(parent=emptyenv())
.shipment_source_signature <- function(x) digest::digest(.shipment_canonical(x),algo='sha256')

load_shipment_base_source <- function(revision_id,root=here::here()) {
  if(!grepl('^202[56]_(basic|rev_[0-9]+)$',revision_id)) stop('Identified 2025/2026 source revision required')
  release <- sub('_rev_','HTSRev',sub('_basic','HTSBasic',revision_id))
  hts <- file.path(root,'data/hts_archives',paste0('hts_',revision_id,'.json'))
  gn3 <- file.path(root,'data/cache/general_notes',paste0('GN3_',release,'.pdf'))
  extractor <- file.path(root,'src/shipment_base_sources.py')
  gn_parser <- file.path(root,'src/parse_general_note_3.R')
  paths <- c(hts,gn3,extractor,gn_parser)
  if(any(!file.exists(paths))) stop('Missing primary shipment base/GN3 source; no country/rate fallback: ',paste(paths[!file.exists(paths)],collapse=', '))
  hash <- function(path)digest::digest(file=path,algo='sha256')
  key <- paste(vapply(paths,hash,character(1)),collapse=':')
  if(identical(.shipment_base_hot$key,key))return(.shipment_base_hot$value)
  target <- tempfile(fileext='.json');on.exit(unlink(target),add=TRUE)
  status <- system2('python3',c(shQuote(extractor),'--hts',shQuote(hts),'--revision',shQuote(revision_id),
    '--output',shQuote(target)))
  if(status!=0L)stop('Complete base-duty source extraction failed')
  x <- jsonlite::fromJSON(target,simplifyVector=FALSE)
  if(!identical(x$source$sha256,hash(hts))||!identical(x$extractor_sha256,hash(extractor)))stop('Base-duty source/hash mismatch')
  text <- system2('pdftotext',c('-layout',shQuote(gn3),'-'),stdout=TRUE)
  if(!length(text))stop('Missing native General Note3 text')
  year <- substr(revision_id,1,4)
  expected <- if(grepl('_rev_',revision_id))sub('.*_rev_','',revision_id) else NULL
  match <- regmatches(text[1],regexec('Revision\\s+([0-9]+)',text[1]))[[1]]
  actual <- if(length(match))match[2] else NULL
  if(!grepl(paste0('\\(',year,'\\)'),text[1])||!identical(expected,actual))stop('General Note3 revision header mismatch')
  env <- new.env(parent=globalenv());sys.source(gn_parser,envir=env)
  roster <- sort(unique(env$parse_gn3_column2(paste(text,collapse='\n'))$country_name))
  if(!length(roster))stop('Missing General Note3(b) country inventory')
  x$gn3 <- list(country_names=as.list(roster),source=list(path=normalizePath(gn3),sha256=hash(gn3),
    url=paste0('https://hts.usitc.gov/reststop/file?release=',release,'&filename=General%20Note%203'),
    citation=paste('USITC',revision_id,'General Note3(a)-(c), including complete Column2 origin table')),
    parser_sha256=hash(gn_parser))
  symbols <- env$parse_gn3_symbols(paste(text,collapse='\n'))
  if(!any(symbols$symbol=='S' & grepl('United States-Mexico-Canada Agreement',symbols$program_name,fixed=TRUE)))
    stop('Native GN3 does not establish the USMCA Special-column symbol')
  x$gn3$program_symbols <- lapply(seq_len(nrow(symbols)),function(i)as.list(symbols[i,]))
  attr(x,'source_integrity') <- .shipment_source_signature(x)
  .shipment_base_hot$key <- key;.shipment_base_hot$value <- x
  x
}

# Consume the entire Special field, retaining each expression and its symbols.
# A valid Free group for one program cannot erase a later conditional reference
# for another. In particular S+ references do not establish quota entitlement.
parse_shipment_special_column <- function(text) {
  if(is.null(text)||!length(text)||!nzchar(trimws(text)))return(list(status='absent',groups=list(),programme_status=structure(list(),names=character())))
  remaining<-text;groups<-list();uncertain<-character();anomalies<-list();global<-FALSE
  # Unknown SPI punctuation is retained, never repaired into an entitlement.
  # Only isolated one/two-letter SPI candidates can localize that uncertainty.
  candidates<-function(value) {
    words<-strsplit(gsub('[.,()]+',' ',value),'\\s+',perl=TRUE)[[1]]
    words<-words[nzchar(words)]
    if(length(words)&&all(grepl('^[A-Z]{1,2}[+*]?$',words)))unique(words) else NULL
  }
  while(nzchar(trimws(remaining))) {
    m<-regmatches(remaining,regexec('^\\s*([^()]+?)\\s*\\(([^()]*)\\)\\s*',remaining,perl=TRUE))[[1]]
    if(!length(m)) {
      # A malformed final See-heading group has no bearing on earlier complete
      # programme groups. Arbitrary unconsumed prose can qualify the whole field.
      tail<-regmatches(remaining,regexec('^\\s*See[[:space:]]+[0-9.,[:space:]–—-]+\\(([A-Z+*(),[:space:]]+)\\s*$',remaining,perl=TRUE))[[1]]
      possible<-if(length(tail))candidates(tail[2]) else NULL
      if(is.null(possible))global<-TRUE else uncertain<-union(uncertain,possible)
      anomalies[[length(anomalies)+1L]]<-list(raw=remaining,reason='unconsumed_special_field',possible_programmes=as.list(possible),whole_field=is.null(possible))
      break
    }
    raw_symbols<-trimws(strsplit(m[3],',',fixed=TRUE)[[1]])
    if(!length(raw_symbols)) {global<-TRUE;anomalies[[length(anomalies)+1L]]<-list(raw=m[1],reason='empty_special_programmes',whole_field=TRUE)}
    valid<-grepl('^[A-Z]{1,2}[+*]?$',raw_symbols)
    for(token in raw_symbols[!valid]) {
      possible<-candidates(token)
      if(is.null(possible))global<-TRUE else uncertain<-union(uncertain,possible)
      anomalies[[length(anomalies)+1L]]<-list(raw=token,reason='unparsed_special_symbol',possible_programmes=as.list(possible),whole_field=is.null(possible))
    }
    expression<-trimws(m[2])
    groups[[length(groups)+1L]]<-list(expression=expression,symbols=as.list(unique(raw_symbols[valid])),
      raw=m[1],raw_symbols=m[3],parsed=parse_shipment_duty_expression(expression))
    remaining<-substring(remaining,nchar(m[1])+1L)
  }
  symbols<-unlist(lapply(groups,`[[`,'symbols'),use.names=FALSE)
  duplicates<-unique(symbols[duplicated(symbols)])
  if(length(duplicates))anomalies[[length(anomalies)+1L]]<-list(reason='duplicate_special_program',possible_programmes=as.list(duplicates))
  uncertain<-union(uncertain,duplicates)
  programmes<-sort(unique(c(symbols,uncertain)))
  statuses<-setNames(lapply(programmes,function(symbol)if(!global&&sum(symbols==symbol)==1L&&!symbol%in%uncertain)'unambiguous' else 'unresolved_source'),programmes)
  list(status=if(!length(anomalies)&&length(groups))'parsed' else 'unresolved_source',groups=groups,
    reason=if(length(anomalies))anomalies[[1]]$reason else NULL,programme_status=statuses,
    unresolved_regions=anomalies,unresolved_whole_field=global)
}

shipment_special_reference <- function(record,symbol) {
  field<-parse_shipment_special_column(record$expression)
  selected<-Filter(function(g)symbol%in%unlist(g$symbols),field$groups)
  parsed<-if(identical(field$programme_status[[symbol]],'unambiguous')&&length(selected)==1L)selected[[1]]$parsed else NULL
  list(raw=record$expression,source_code=record$source_code,source_row_index=record$source_row_index,
    expression=if(length(selected)==1L)selected[[1]]$expression else NULL,normalized_text=parsed$normalized_text,field_status=field$status,
    symbol=symbol,groups=field$groups,programme_status=field$programme_status,
    unresolved_regions=field$unresolved_regions,status=if(!is.null(parsed))parsed$status else 'unresolved_source',
    formula=if(!is.null(parsed)&&parsed$status=='parsed')parsed$formula else
      list(unresolved_source=paste0(if(symbol=='S')'column1_usmca_special_expression:' else paste0('column1_',symbol,'_special_expression:'),field$reason %||% 'conditional_or_absent_programme_expression')),
    fact_definitions=parsed$fact_definitions %||% list(),input_constraints=parsed$input_constraints %||% list())
}

shipment_usmca_reference <- function(record)shipment_special_reference(record,'S')

# Independent legal benchmark expressions, before another action changes or
# suppresses the payable base component. Shared by sector compilers; callers
# must separately reconcile any preference or Chapter98 claim.
compile_shipment_column1_references <- function(extraction,products,strict=TRUE,question_prefix='column1_general_expression') {
  if(is.null(attr(extraction,'source_integrity'))||
     !identical(attr(extraction,'source_integrity'),.shipment_source_signature(extraction)))stop('Unvalidated Column1 reference extraction')
  native<-setNames(extraction$products,vapply(extraction$products,`[[`,character(1),'hts10'))
  products<-sort(unique(as.character(products)))
  if(strict&&any(!products%in%names(native)))stop('Product is not valid in the identified Column1 source revision')
  setNames(lapply(products,function(p) {
    record<-native[[p]]$general
    parsed<-parse_shipment_duty_expression(record$expression)
    list(raw=record$expression,normalized_text=parsed$normalized_text,normalization_steps=parsed$normalization_steps,
      source_code=record$source_code,source_row_index=record$source_row_index,status=parsed$status,
      formula=if(parsed$status=='parsed')parsed$formula else list(unresolved_source=paste(question_prefix,p,parsed$reason,sep=':')),
      fact_definitions=parsed$fact_definitions,input_constraints=parsed$input_constraints %||% list(),
      usmca=shipment_usmca_reference(native[[p]]$special))
  }),products)
}

compile_shipment_base_fragment <- function(extraction,products,countries,root=here::here()) {
  if(is.null(attr(extraction,'source_integrity'))||
     !identical(attr(extraction,'source_integrity'),.shipment_source_signature(extraction)))
    stop('Unvalidated or changed shipment base extraction')
  x <- extraction;revision <- x$revision
  products <- sort(unique(as.character(products)));countries <- sort(unique(as.character(countries)))
  if(!length(products)||any(!grepl('^[0-9]{10}$',products))||!length(countries)||any(!grepl('^[0-9]{4}$',countries)))
    stop('Exact products and Census origins required')
  records <- setNames(x$products,vapply(x$products,`[[`,character(1),'hts10'))
  special <- setNames(x$special_classifications,vapply(x$special_classifications,`[[`,character(1),'hts10'))
  if(any(!products %in% c(names(records),names(special))))stop('Product outside revision-valid source inventory')
  ordinary_products <- intersect(products,names(records))
  sources <- lapply(c('base','gn3'),function(kind) {
    s <- if(kind=='base')x$source else x$gn3$source
    if(!file.exists(s$path)||!identical(s$sha256,digest::digest(file=s$path,algo='sha256')))stop('Changed shipment base primary source')
    list(id=paste0('USITC-',revision,'-shipment-',kind),status='verified',sha256=s$sha256,url=s$url,citation=s$citation)
  })
  ids <- vapply(sources,`[[`,character(1),'id')
  artifacts <- list(list(source_id=ids[1],path=x$source$path,sha256=x$source$sha256),
                    list(source_id=ids[2],path=x$gn3$source$path,sha256=x$gn3$source$sha256))
  ftz<-compile_ftz_valuation(root)
  sources<-c(sources,ftz$sources);artifacts<-c(artifacts,ftz$source_artifacts)
  ids<-vapply(sources,`[[`,character(1),'id')
  roster <- unlist(x$gn3$country_names)
  resolved <- lapply(roster,resolve_country_name)
  if(any(lengths(resolved)!=1L))stop('Unresolved or ambiguous primary GN3 origin inventory')
  column2 <- sort(unique(as.character(unlist(resolved))))
  census <- as.character(read.csv(file.path(root,'resources/census_codes.csv'),colClasses='character')$Code)
  if(any(!countries %in% census)||any(!column2 %in% census))stop('Origin outside identified Census inventory')
  facts <- list(ieepa_ftz_entry=list(type='boolean',label='Entry from a foreign trade zone',source_ids=as.list(ids),
    description='An ordinary consumption entry uses this revision. An FTZ withdrawal also needs admission, status and classification/rate history; see19CFR146.65.'))
  facts$usmca_origin_eligible<-list(type='boolean',label='Qualifies under General Note 11',source_ids=as.list(ids),
    description='Verified preferential-origin eligibility. Nonpreferential country of origin alone does not establish this fact.')
  facts$usmca_properly_claimed<-list(type='boolean',label='USMCA treatment properly claimed for this entry',source_ids=as.list(ids))
  facts<-c(facts,ftz$fact_definitions)
  rules <- list();coverage <- list();source_rows <- list()
  for(treatment in c('column1_general','column2')) {
    origins <- if(treatment=='column2')intersect(countries,column2) else setdiff(countries,column2)
    if(!length(origins))next
    field <- if(treatment=='column2')'column2' else 'general'
    expressions <- vapply(records[ordinary_products],function(p)p[[field]]$expression %||% '',character(1))
    # Missing/unrelated owners must retain their individual source questions;
    # never collapse several malformed source branches to one generic zero.
    special_expressions<-if(treatment=='column1_general')vapply(records[ordinary_products],function(p)p$special$expression %||% '',character(1)) else rep('',length(ordinary_products))
    groups <- split(ordinary_products,paste(ifelse(nzchar(expressions),expressions,paste0('<unresolved>:',ordinary_products)),special_expressions,sep='\nSPECIAL\n'))
    rule_ids <- character()
    for(group in groups) {
      raw <- records[[group[1]]][[field]]$expression
      parsed <- parse_shipment_duty_expression(raw)
      for(name in names(parsed$fact_definitions)) {
        definition <- parsed$fact_definitions[[name]];definition$source_ids <- as.list(ids)
        old <- facts[[name]]
        if(!is.null(old)&&!identical(old,definition))stop('Conflicting legal base valuation unit')
        facts[[name]] <- definition
      }
      id <- paste0('base_',revision,'_',treatment,'_',substr(digest::digest(list(raw,special_expressions[match(group[1],ordinary_products)]),algo='sha256'),1,16))
      record <- records[[group[1]]]
      errors <- Filter(function(e)grepl(field,e,fixed=TRUE),as.list(record$source_errors))
      formula <- if(parsed$status=='parsed')parsed$formula else
        list(unresolved_source=paste0('base_source:',revision,':',group[1],':',field,':',
          paste(unlist(errors),collapse=','),':owner=',record[[field]]$source_code %||% '<none>',
          ':row=',record[[field]]$source_row_index %||% '<none>',':',parsed$reason,':',raw %||% '<missing>'))
      constraints<-parsed$input_constraints %||% list()
      preference<-NULL
      if(treatment=='column1_general') {
        preference<-shipment_usmca_reference(record$special)
        # GN3(c)(i), symbol S; entitlement remains a shipment fact under GN11.
        # Preserve S+ and other reference-only paths as source questions.
        unchanged_free<-identical(formula,list(value=0))&&is.null(preference$raw)
        if(!unchanged_free&&!identical(formula,preference$formula)) {
          formula<-list(op='if',args=list(list(claim='USMCA'),preference$formula,formula))
          constraints<-lapply(constraints,function(c) {c$test<-list(op='if',args=list(list(claim='USMCA'),list(value=TRUE),c$test));c})
          for(c in preference$input_constraints) {
            c$test<-list(op='if',args=list(list(claim='USMCA'),c$test,list(value=TRUE)));constraints[[length(constraints)+1L]]<-c
          }
          if(identical(preference$status,'parsed'))constraints[[length(constraints)+1L]]<-list(test=list(op='if',args=list(list(claim='USMCA'),
            list(op='and',args=list(list(fact='usmca_origin_eligible'),list(fact='usmca_properly_claimed'))),list(value=TRUE))),
            inputs=list('usmca_origin_eligible','usmca_properly_claimed'),reason='USMCA entitlement and proper claim must be established')
        }
        for(name in names(preference$fact_definitions))facts[[name]]<-c(preference$fact_definitions[[name]],list(source_ids=as.list(ids)))
      }
      # NPF (including recoverable waste under146.42(b)) uses constructive-
      # transfer classification/quantity. Its valuation is146.65(b), not an
      # importer-supplied ordinary customs value. PF needs historical rates.
      consumes_value<-function(node) {
        if(identical(node,list(fact='customs_value')))return(TRUE)
        is.list(node)&&any(vapply(node,consumes_value,logical(1)))
      }
      replace_value<-function(node) {
        if(identical(node,list(fact='customs_value')))return(ftz$formula)
        if(is.list(node))lapply(node,replace_value) else node
      }
      ftz_formula<-replace_value(formula)
      npf<-list(op='or',args=lapply(c('nonprivileged_foreign','recoverable_waste'),function(status)
        list(op='eq',args=list(list(fact='ftz_status'),list(value=status)))))
      # Until the preferential FTZ admission rules are reconciled, an ordinary
      # preference formula cannot be reused to price an FTZ claim.
      preference_requested<-list(op='or',args=list(list(claim='USMCA'),list(claim='COLUMN1_SPECIAL'),list(claim='CHAPTER_98')))
      priced_npf<-list(op='and',args=list(npf,list(op='not',args=list(preference_requested))))
      ftz_formula<-list(op='if',args=list(preference_requested,
        list(unresolved_source='base_ftz_preference_and_chapter98_admission_treatment'),ftz_formula))
      for(i in seq_along(constraints))constraints[[i]]$test<-list(op='if',args=list(list(fact='ieepa_ftz_entry'),
        list(op='if',args=list(priced_npf,replace_value(constraints[[i]]$test),list(value=TRUE))),constraints[[i]]$test))
      if(consumes_value(formula))for(constraint in ftz$constraints) {
        constraint$test<-list(op='if',args=list(list(op='and',args=list(list(fact='ieepa_ftz_entry'),priced_npf)),constraint$test,list(value=TRUE)))
        constraints[[length(constraints)+1L]]<-constraint
      }
      formula <- list(op='if',args=list(list(fact='ieepa_ftz_entry'),
        list(op='if',args=list(npf,ftz_formula,list(op='if',args=list(
          list(op='eq',args=list(list(fact='ftz_status'),list(value='domestic'))),
          list(unresolved_source='base_ftz_domestic_status_and_production_reconciliation'),
          list(unresolved_source='base_ftz_admission_classification_and_rate_history'))))),formula))
      rule <- list(id=id,action_id='ordinary_customs_duty',authority='base',kind='duty',verification='verified',
        base_treatment=treatment,scope=list(hts_exact=as.list(group),countries=as.list(origins)),formula=formula,
        published_expression=raw,normalized_expression=parsed$normalized_text,
        expression_normalization_steps=parsed$normalization_steps,reporting_codes=list(),source_ids=as.list(ids),
        legal_locator=paste('Native',revision,treatment,'duty column; General Note3; source owner map'),
        input_constraints=constraints,column1_special_reference=preference)
      rules[[length(rules)+1L]] <- rule;rule_ids <- c(rule_ids,id)
      for(hts in group)source_rows[[length(source_rows)+1L]] <- list(hts10=hts,rule_id=id,treatment=treatment,
        source_code=records[[hts]][[field]]$source_code,source_row_index=records[[hts]][[field]]$source_row_index,
        expression=raw,footnotes=records[[hts]][[field]]$footnotes,source_errors=records[[hts]]$source_errors)
    }
    if(length(ordinary_products))coverage[[length(coverage)+1L]] <- list(authority='base',status='verified',determination='rules',
      scope=list(hts_exact=as.list(ordinary_products),countries=as.list(origins)),rule_ids=as.list(sort(rule_ids)),source_ids=as.list(ids))
  }
  for(hts in intersect(products,names(special))) {
    record <- special[[hts]]
    rule <- list(id=paste0('special_classification_',revision,'_',hts),action_id='chapter98_special_classification',
      authority='base',kind='duty',verification='verified',base_treatment='conditional_special_classification',
      scope=list(hts_exact=list(hts),countries=as.list(countries)),source_ids=as.list(ids),reporting_codes=list(),
      published_expression=record$general$expression,published_description=record$description,
      legal_locator=paste('USITC',revision,'Chapter98',record$native_code,'published eligibility and duty expression'),
      formula=list(unresolved_source=paste0('chapter98_entitlement_valuation_and_cross_program_reconciliation:',hts)))
    rules[[length(rules)+1L]] <- rule
    coverage[[length(coverage)+1L]] <- list(authority='base',status='unresolved_source',rule_ids=list(rule$id),
      source_ids=as.list(ids),scope=rule$scope,question='Reconcile the special-classification entitlement, applicable ordinary classification when needed, valuation and each additional program. A printed Free expression is conditional.')
    source_rows[[length(source_rows)+1L]] <- list(hts10=hts,rule_id=rule$id,treatment='conditional_special_classification',
      source_code=record$general$source_code,source_row_index=record$general$source_row_index,expression=record$general$expression,
      footnotes=record$general$footnotes,source_errors=record$source_errors)
  }
  selection <- shipment_source_selection_window(revision,root)
  preference_rules<-vapply(Filter(function(r)identical(r$base_treatment,'column1_general'),rules),`[[`,character(1),'id')
  list(contract_version='sail.shipment-rule-fragment/v1',id=paste0('shipment_base_',revision),sources=sources,
    supported_from=selection$from,supported_until=selection$until,source_selection_window=selection,
    source_artifacts=artifacts,rules=rules,fact_definitions=facts,
    claim_definitions=if(length(preference_rules))list(list(id='USMCA',label='USMCA',source_ids=as.list(ids),
      rule_ids=as.list(preference_rules))) else list(),
    derived_facts=setNames(lapply(c('s122_ftz_entry','s338_ftz_entry'),function(alias)
      list(expression=list(fact='ieepa_ftz_entry'),source_ids=lapply(ftz$sources,`[[`,'id'))),c('s122_ftz_entry','s338_ftz_entry')),
    relations=list(),coverage=coverage,
    base_source_map=source_rows,source_inventory=list(products=as.list(sort(names(records))),
      special_classifications=as.list(sort(names(special))),product_count=length(records),
      source_sha256=x$source$sha256,extractor_sha256=x$extractor_sha256),
    compiler_dependencies=list(shipment_build=digest::digest(file=file.path(root,'src/shipment_build.R'),algo='sha256'),
      expression_parser=digest::digest(file=file.path(root,'src/shipment_duty_expression.R'),algo='sha256'),
      ftz_valuation=ftz$compiler_sha256,
      gn3_parser=x$gn3$parser_sha256,country_resolver=digest::digest(file=file.path(root,'src/helpers.R'),algo='sha256'),
      country_mapping=digest::digest(file=file.path(root,'resources/census_codes.csv'),algo='sha256'),
      curated_country_mapping=digest::digest(file=file.path(root,'resources/country_name_aliases.csv'),algo='sha256'),
      qualified_country_mapping=digest::digest(file=file.path(root,'resources/country_qualified_names.csv'),algo='sha256'),
      source_calendar=digest::digest(file=file.path(root,'config/revision_dates.csv'),algo='sha256'),
      build_contract=digest::digest(file=file.path(root,'resources/shipment_rules/build_contract.json'),algo='sha256')),
    limitations=list('General, Column2 and direct S expressions; NPF and recoverable-waste base valuation under146.65. S+ references, other preferences, Chapter98, domestic-zone and PF rate histories require separate reconciliation. No other-authority coverage is attested.'))
}

# Fixed production inventory. Fragment presence, a positive rate, or a successful
# source export cannot remove an authority from this completeness requirement.
SHIPMENT_BUILD_SPEC <- jsonlite::fromJSON(here::here('resources/shipment_rules/build_contract.json'),simplifyVector=FALSE)
if(!identical(SHIPMENT_BUILD_SPEC$contract_version,'sail.shipment-build/v1'))stop('Unsupported shipment build specification')
SHIPMENT_BUILD_AUTHORITIES <- unlist(SHIPMENT_BUILD_SPEC$coverage_authorities,use.names=FALSE)

shipment_source_selection_window <- function(revision,root=here::here()) {
  path <- file.path(root,'config/revision_dates.csv')
  raw <- read.csv(path,colClasses='character')
  calendar <- load_revision_dates(path,use_policy_dates=TRUE)
  i <- match(revision,calendar$revision);j <- match(revision,raw$revision)
  if(is.na(i)||is.na(j))stop('Missing identified build source interval')
  from <- .shipment_day_start(calendar$effective_date[i])
  until <- if(i<nrow(calendar)).shipment_day_start(calendar$effective_date[i+1L]) else SHIPMENT_BUILD_SPEC$audit_until
  if(.shipment_time(until)>.shipment_time(SHIPMENT_BUILD_SPEC$audit_until))until <- SHIPMENT_BUILD_SPEC$audit_until
  if(.shipment_time(from)<.shipment_time(SHIPMENT_BUILD_SPEC$audit_from))from <- SHIPMENT_BUILD_SPEC$audit_from
  if(.shipment_time(from)>=.shipment_time(until))stop('Source interval is outside the audited build scope')
  list(from=from,until=until,raw_hts_date=raw$effective_date[j],
    aggregate_policy_date=if(is.na(raw$policy_effective_date[j]))NULL else raw$policy_effective_date[j],
    role=SHIPMENT_BUILD_SPEC$source_selection_role,calendar_sha256=digest::digest(file=path,algo='sha256'),
    limitation='This interval selects the build source. Classification validity and statutory effective instants require their own legal reconciliation.')
}

if(!exists('.shipment_context_hot',inherits=FALSE)).shipment_context_hot <- new.env(parent=emptyenv())
load_shipment_build_context <- function(root=here::here()) {
  evidence <- Sys.getenv('SAIL_DUTY_EVIDENCE_MANIFEST','')
  grants <- Sys.getenv('SECTION232_GRANT_SNAPSHOT','')
  # Cache only while every source or interchange artifact has the same physical
  # fingerprint. The authoritative identity below hashes bytes, not mtimes.
  roots <- file.path(root,c('src','config','resources',
    'data/hts_archives','data/us_notes','data/cache/general_notes'))
  paths <- sort(unique(c(unlist(lapply(roots,function(p)list.files(p,recursive=TRUE,full.names=TRUE))),
    file.path(root,'resources/census_codes.csv'),file.path(root,'frontend/server/generated/shipmentRules.js'),
    file.path(root,'frontend/server/generated/shipmentWide.js'),
    if(nzchar(evidence))list.files(dirname(evidence),recursive=TRUE,full.names=TRUE),
    if(nzchar(grants))list.files(dirname(grants),recursive=TRUE,full.names=TRUE))))
  info <- file.info(paths)
  key <- digest::digest(list(paths,info$size,as.numeric(info$mtime),as.numeric(info$ctime),evidence,grants),algo='sha256')
  if(identical(.shipment_context_hot$key,key))return(.shipment_context_hot$value)
  output <- tempfile(fileext='.json');on.exit(unlink(output),add=TRUE)
  args <- c(shQuote(file.path(root,'src/shipment_build_context.py')),'--root',shQuote(root),'--output',shQuote(output))
  if(nzchar(evidence))args <- c(args,'--evidence',shQuote(evidence))
  if(nzchar(grants))args <- c(args,'--grants',shQuote(grants))
  if(system2('python3',args)!=0L)stop('Shipment source/evidence context validation failed')
  value <- jsonlite::fromJSON(output,simplifyVector=FALSE)
  .shipment_context_hot$key <- key;.shipment_context_hot$value <- value
  value
}

.shipment_json <- function(x)as.character(jsonlite::toJSON(x,auto_unbox=TRUE,null='null',na='null',digits=17))
.shipment_iso <- function(x)format(as.POSIXct(x,origin='1970-01-01',tz='UTC'),'%Y-%m-%dT%H:%M:%SZ',tz='UTC')
.shipment_day_start <- function(x)format(as.POSIXct(paste(as.Date(x),'00:00:00'),tz='America/New_York'),
  '%Y-%m-%dT%H:%M:%S%z',tz='America/New_York') |> sub('([+-][0-9]{2})([0-9]{2})$','\\1:\\2',x=_)

.shipment_verified_bundle <- function(index,entry,dir) {
  if(!is.character(entry$path)||length(entry$path)!=1||!grepl('^shipment_bundle_[a-f0-9]{64}\\.json$',entry$path))
    stop('Invalid shipment bundle artifact path')
  path <- file.path(dir,entry$path)
  if(!file.exists(path)||!startsWith(normalizePath(path),paste0(normalizePath(dir),'/'))||
     !identical(digest::digest(file=path,algo='sha256'),entry$sha256))stop('Shipment bundle hash mismatch')
  b <- jsonlite::fromJSON(path,simplifyVector=FALSE)
  if(!identical(b$contract_version,'sail.shipment-rules/v1')||!identical(b$bundle_id,entry$bundle_id)||
    !identical(b$dataset_version,index$dataset_version)||!identical(b$evidence_snapshot_id,index$evidence_snapshot_id)||
    !identical(b$revision,index$revision)||!identical(b$valid_from,entry$valid_from)||!identical(b$valid_until,entry$valid_until)||
    !setequal(unlist(b$coverage_requirements),SHIPMENT_BUILD_AUTHORITIES))stop('Mixed or incomplete shipment build contract')
  b
}

assemble_shipment_state <- function(revision,products,countries,valid_from,valid_until,fragments,context,output_dir) {
  products <- sort(unique(as.character(products)));countries <- sort(unique(as.character(countries)))
  if(!length(products)||any(!grepl('^[0-9]{10}$',products))||!length(countries)||any(!grepl('^[0-9]{4}$',countries)))stop('Invalid shipment grid')
  if(!is.character(context$dataset_version)||!nzchar(context$dataset_version)||
    !is.character(context$evidence_snapshot_id)||!nzchar(context$evidence_snapshot_id))stop('Unidentified shipment build inputs')
  start <- .shipment_time(.shipment_day_start(valid_from));end <- .shipment_time(.shipment_day_start(as.Date(valid_until)+1))
  if(is.na(start)||is.na(end)||end<=start)stop('Exact shipment build interval required')
  # Every relevant instant, including amendments within one HTS revision, is
  # evaluated. Legal dates are not rounded to the daily aggregate calendar.
  instants <- c(start,end)
  for(f in fragments) {
    boundaries <- c(f$supported_from,f$supported_until,f$legal_horizon$from_,f$legal_horizon$until,
      unlist(lapply(c(f$rules,f$coverage),function(r)c(r$scope$from,r$scope$until))),
      unlist(lapply(f$relations,function(r)c(r$source_window$from,r$source_window$until))))
    if(length(boundaries)) {
      times <- vapply(boundaries,.shipment_time,numeric(1))
      if(anyNA(times))stop('Invalid source/rule horizon in fragment: ',f$id)
      instants <- c(instants,times[times>start & times<end])
    }
  }
  instants <- sort(unique(instants));entries <- list()
  source_windows <- Filter(function(f)!is.null(f$source_selection_window),fragments)
  if(length(source_windows)!=1L)stop('One identified source-selection frame is required')
  source_window <- source_windows[[1]]$source_selection_window
  dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
  for(i in seq_len(length(instants)-1L)) {
    from <- instants[i];until <- instants[i+1L];selected <- list();questions <- list()
    source_supported <- from>=.shipment_time(source_window$from)&&until<=.shipment_time(source_window$until)
    for(f in fragments) {
      lower <- max(c(-Inf,vapply(c(f$supported_from,f$legal_horizon$from_),.shipment_time,numeric(1))))
      upper <- min(c(Inf,vapply(c(f$supported_until,f$legal_horizon$until),.shipment_time,numeric(1))))
      if(source_supported&&from>=lower && until<=upper)selected[[length(selected)+1L]] <- f
      else questions[[length(questions)+1L]] <- list(fragment_id=f$id,
        reason=if(source_supported)'outside_executable_horizon' else 'outside_build_source_interval',
        authorities=as.list(sort(unique(vapply(f$rules,`[[`,character(1),'authority')))),
        supported_from=f$supported_from,supported_until=f$supported_until,legal_horizon=f$legal_horizon,
        source_ids=lapply(f$sources,`[[`,'id'),source_selection_window=if(source_supported)NULL else source_window,
        question=if(source_supported)'Reconcile original instruments and amendments before extending this executable fragment.' else
          'Choose the identified build source for this entry interval. This source-selection bound does not determine statutory effectiveness or settle classification chronology.')
    }
    b <- list(contract_version='sail.shipment-rules/v1',dataset_version=context$dataset_version,revision=revision,
      evidence_snapshot_id=context$evidence_snapshot_id,valid_from=.shipment_iso(from),valid_until=.shipment_iso(until),
      products=as.list(products),countries=as.list(countries),sources=list(),rules=list(),coverage=list(),
      coverage_requirements=as.list(SHIPMENT_BUILD_AUTHORITIES),fact_definitions=list(),claim_definitions=list(),
      evidence_dependencies=list(build_inputs=context$input_manifest,evidence_snapshot=context$evidence_pin,source_selection=source_window),
      unresolved_questions=questions)
    b <- compose_shipment_rules(b,selected)
    # An explicit question is retained alongside every unreviewed inventory.
    # It is not promoted to a no-applicable-rules determination.
    for(authority in SHIPMENT_BUILD_AUTHORITIES) {
      if(!any(vapply(b$coverage,function(c)identical(c$authority,authority),logical(1))))
        b$coverage[[length(b$coverage)+1L]] <- list(authority=authority,status='unresolved_source',rule_ids=list(),source_ids=list(),
          unresolved_fragments=Filter(function(q)!length(q$authorities)||authority %in% unlist(q$authorities),questions),
          question=if(authority=='trade_intelligence_evidence') 'Pin and reconcile the identified trade-intelligence evidence export.' else
            paste('Reconcile all operative',authority,'actions, exclusions, claims and interactions in this interval; fragment presence does not establish full inventory coverage.'))
    }
    b$bundle_id <- .shipment_source_signature(b)
    filename <- paste0('shipment_bundle_',b$bundle_id,'.json')
    jsonlite::write_json(b,file.path(output_dir,filename),auto_unbox=TRUE,null='null',digits=17)
    entries[[length(entries)+1L]] <- list(bundle_id=b$bundle_id,path=filename,
      sha256=digest::digest(file=file.path(output_dir,filename),algo='sha256'),valid_from=b$valid_from,valid_until=b$valid_until)
  }
  index <- list(contract_version='sail.shipment-bundle-index/v1',revision=revision,dataset_version=context$dataset_version,
    evidence_snapshot_id=context$evidence_snapshot_id,source_selection=source_window,
    valid_from=.shipment_iso(start),valid_until=.shipment_iso(end),bundles=entries)
  jsonlite::write_json(index,file.path(output_dir,'shipment_rules.json'),auto_unbox=TRUE,null='null',digits=17)
  index
}

merge_shipment_bundle_indexes <- function(indexes,dirs) {
  if(!length(indexes)||length(indexes)!=length(dirs))stop('Missing shipment state indexes')
  first <- indexes[[1]]
  entries <- list();products <- countries <- NULL
  for(i in seq_along(indexes)) {
    x <- indexes[[i]]
    for(key in c('contract_version','revision','dataset_version','evidence_snapshot_id'))
      if(!identical(x[[key]],first[[key]]))stop('Mixed shipment index/source versions')
    if(!identical(x$contract_version,'sail.shipment-bundle-index/v1')||!length(x$bundles))stop('Missing shipment bundle index')
    for(entry in x$bundles) {
      b <- .shipment_verified_bundle(x,entry,dirs[i])
      if(is.null(products)){products<-b$products;countries<-b$countries}
      if(!identical(b$products,products)||!identical(b$countries,countries))stop('Incomplete shipment grid across legal states')
      entries[[length(entries)+1L]] <- entry
    }
  }
  starts <- vapply(entries,function(e).shipment_time(e$valid_from),numeric(1))
  entries <- entries[order(starts)];starts <- sort(starts)
  ends <- vapply(entries,function(e).shipment_time(e$valid_until),numeric(1))
  if(anyNA(c(starts,ends))||any(starts>=ends)||any(head(ends,-1)!=tail(starts,-1)))
    stop('Shipment state intervals do not tile exactly')
  first$valid_from <- entries[[1]]$valid_from;first$valid_until <- tail(entries,1)[[1]]$valid_until
  first$bundles <- entries;first
}

# A conservative symbolic check, not a sampled rate calculation. Only expressions
# proven homogeneous in the declared customs-value basis may become scalar rates.
# Prove invariance under positive scaling of customs_value, including rules
# that are inactive at the USD1 reference point. This is a proof of whether a
# scalar projection is valid, not a second calculator or a sampled liability.
.shipment_projection_proof <- function(rules,matched,claims=list()) {
  bad <- function()list(degree=NA_integer_,zero=FALSE)
  degree <- function(n,zero=FALSE)list(degree=as.integer(n),zero=zero)
  condition_cache <- new.env(hash=TRUE,parent=emptyenv())
  value_cache <- new.env(hash=TRUE,parent=emptyenv())
  constant <- function(x) {
    if(!is.list(x))return(NULL)
    if(is.logical(x$value)&&length(x$value)==1L&&!is.na(x$value))return(x$value)
    if(!is.null(x$claim))return(x$claim %in% unlist(claims))
    if(identical(x$op,'if')&&length(x$args)==3L) {
      test <- constant(x$args[[1]])
      if(!is.null(test))return(constant(x$args[[if(test)2L else 3L]]))
    }
    xs <- lapply(x$args,constant)
    if(identical(x$op,'not')&&length(xs)==1L&&!is.null(xs[[1]]))return(!xs[[1]])
    if(isTRUE(x$op %in% c('and','or'))) {
      decisive <- identical(x$op,'or')
      if(any(vapply(xs,identical,logical(1),decisive)))return(decisive)
      if(length(xs)&&all(vapply(xs,is.logical,logical(1))))
        return(if(decisive)any(unlist(xs)) else all(unlist(xs)))
    }
    NULL
  }
  independent <- function(x,visiting) {
    if(!is.list(x))return(FALSE)
    if(!is.null(x$value)||!is.null(x$claim)||!is.null(x$authority_covered)||!is.null(x$unresolved_source))return(TRUE)
    if(!is.null(x$fact))return(!identical(x$fact,'customs_value'))
    if(!is.null(x$rule_applies))return(rule_invariant(x$rule_applies,FALSE,visiting))
    if(!is.null(x$rule_amount)) {
      d <- linear(x,visiting);return(!is.na(d$degree)&&(d$zero||d$degree==0L))
    }
    !is.null(x$op)&&length(x$args)>0L&&all(vapply(x$args,independent,logical(1),visiting=visiting))
  }
  condition <- function(x,visiting=character()) {
    if(!is.null(constant(x)))return(TRUE)
    if(independent(x,visiting))return(TRUE)
    if(isTRUE(x$op %in% c('and','or','not')))return(length(x$args)>0L&&
      all(vapply(x$args,condition,logical(1),visiting=visiting)))
    if(identical(x$op,'if')&&length(x$args)==3L) {
      test <- constant(x$args[[1]])
      if(!is.null(test))return(condition(x$args[[if(test)2L else 3L]],visiting))
      return(all(vapply(x$args,condition,logical(1),visiting=visiting)))
    }
    if(isTRUE(x$op %in% c('eq','lt','lte','gt','gte'))&&length(x$args)==2L) {
      xs <- lapply(x$args,linear,visiting=visiting)
      if(any(vapply(xs,function(d)is.na(d$degree),logical(1))))return(FALSE)
      # Positive scaling preserves a comparison between like-degree values,
      # or between a homogeneous value and zero; it does not preserve CV > 10.
      return(xs[[1]]$degree==xs[[2]]$degree||xs[[1]]$zero||xs[[2]]$zero)
    }
    FALSE
  }
  rule_invariant_impl <- function(id,price=TRUE,visiting=character()) {
    if(is.null(rules[[id]])||id %in% visiting)return(FALSE)
    if(!id %in% matched)return(TRUE) # Scope is fixed by HTS/origin/entry instant.
    r <- rules[[id]];visiting <- c(visiting,id)
    if(identical(constant(r$when),FALSE))return(TRUE)
    if(!is.null(r$when)&&!condition(r$when,visiting))return(FALSE)
    if(!is.null(r$suppressed_when)&&!condition(r$suppressed_when,visiting))return(FALSE)
    if(identical(constant(r$suppressed_when),TRUE))return(TRUE)
    !price||all(vapply(r$input_constraints,function(c)condition(c$test,visiting),logical(1)))
  }
  rule_invariant <- function(id,price=TRUE,visiting=character()) {
    if(id %in% visiting)return(FALSE)
    key <- paste0(if(price)'amount:' else 'applies:',id)
    if(exists(key,envir=condition_cache,inherits=FALSE))return(condition_cache[[key]])
    answer <- rule_invariant_impl(id,price,visiting)
    condition_cache[[key]] <- answer;answer
  }
  rule_value <- function(id,visiting) {
    if(id %in% visiting)return(bad())
    if(exists(id,envir=value_cache,inherits=FALSE))return(value_cache[[id]])
    if(!rule_invariant(id,TRUE,visiting))return(bad())
    if(!id %in% matched)return(degree(0L,TRUE))
    r <- rules[[id]]
    answer <- if(identical(constant(r$when),FALSE)||identical(constant(r$suppressed_when),TRUE))degree(0L,TRUE) else
      linear(r$formula,c(visiting,id))
    value_cache[[id]] <- answer;answer
  }
  linear <- function(node,visiting=character()) {
    if(!is.list(node))return(bad())
    if(!is.null(node$value))return(if(is.numeric(node$value))degree(0L,node$value==0) else bad())
    if(!is.null(node$fact))return(degree(if(identical(node$fact,'customs_value'))1L else 0L))
    if(!is.null(node$rule_amount))return(rule_value(node$rule_amount,visiting))
    if(identical(node$op,'if')) {
      if(length(node$args)!=3L)return(bad())
      test <- constant(node$args[[1]])
      if(!is.null(test))return(linear(node$args[[if(test)2L else 3L]],visiting))
      if(!condition(node$args[[1]],visiting))return(bad())
      xs <- lapply(node$args[-1],linear,visiting=visiting)
    } else xs <- lapply(node$args,linear,visiting=visiting)
    if(!length(xs)||any(vapply(xs,function(x)is.na(x$degree),logical(1))))return(bad())
    ds <- vapply(xs,`[[`,integer(1),'degree');zs <- vapply(xs,`[[`,logical(1),'zero')
    if(isTRUE(node$op %in% c('add','subtract','min','max','if'))) {
      nonzero <- unique(ds[!zs]);if(length(nonzero)>1L)return(bad())
      return(degree(if(length(nonzero))nonzero else 0L,all(zs)))
    }
    if(identical(node$op,'multiply'))return(degree(sum(ds),any(zs)))
    if(identical(node$op,'divide')&&length(ds)==2L&&!zs[2])return(degree(ds[1]-ds[2],zs[1]))
    bad()
  }
  list(value=linear,rule_invariant=rule_invariant)
}

.shipment_compact_decision <- function(result) {
  out <- shipment_result_for_json(result)
  # Source text, scope arrays and formulas live in the immutable bundle once.
  out$required_facts <- NULL;out$claim_options <- NULL
  out$components <- lapply(out$components,function(c)c[setdiff(names(c),c('formula','citations'))])
  out$rule_decisions <- lapply(out$rule_decisions,function(c)c[setdiff(names(c),c('scope','when','suppressed_when','citations'))])
  out$coverage_decisions <- lapply(out$coverage_decisions,function(c) {
    c$attestations <- lapply(c$attestations,function(a) {
      a$unresolved_fragment_ids <- lapply(a$unresolved_fragments,`[[`,'fragment_id')
      a[setdiff(names(a),c('scope','citations','unresolved_fragments'))]
    });c
  })
  out
}

.shipment_rate_projection <- function(result,bundle) {
  mapping <- c(base='statutory_base_rate',section_232='statutory_rate_232',section_301='statutory_rate_301',
    ieepa_reciprocal='statutory_rate_ieepa_recip',ieepa_fentanyl='statutory_rate_ieepa_fent',section_122='statutory_rate_s122',
    section_201='statutory_rate_section_201',section_338='statutory_rate_s338',other_chapter99='statutory_rate_other')
  values <- setNames(as.list(rep(NA_real_,length(mapping))),unname(mapping))
  rules <- setNames(bundle$rules,vapply(bundle$rules,`[[`,character(1),'id'))
  matched <- vapply(result$rule_decisions,`[[`,character(1),'rule_id')
  proof <- .shipment_projection_proof(rules,matched)
  exact <- attr(result,'shipment_exact_amounts')
  exact_sum <- function(ids) {
    if(!length(ids))return(0)
    if(any(!ids %in% names(exact)))return(NA_real_)
    .shipment_rational_number(Reduce(`+`,exact[ids]))
  }
  missing <- character()
  stable <- function(ids)all(vapply(ids,proof$rule_invariant,logical(1)))
  resolved_ids <- vapply(Filter(function(d)d$outcome!='unresolved',result$rule_decisions),`[[`,character(1),'rule_id')
  # An unanswered outer predicate may make value irrelevant. Let the actual
  # interpreter request that predicate first rather than pre-asking both paths.
  if(!stable(resolved_ids))missing <- 'customs_value'
  for(authority in names(mapping)) {
    coverage <- Filter(function(c)identical(c$authority,authority),result$coverage_decisions)
    if(length(coverage)!=1L||!identical(coverage[[1]]$status,'verified'))next
    ids <- matched[vapply(rules[matched],function(r)identical(r$authority,authority),logical(1))]
    if(!stable(ids))next
    cs <- Filter(function(c)identical(c$authority,authority),result$components)
    if(any(!vapply(cs,function(c)identical(c$status,'applied')||identical(c$status,'suppressed'),logical(1))))next
    applied <- Filter(function(c)identical(c$status,'applied'),cs)
    proven <- vapply(applied,function(c) {
      d <- proof$value(rules[[c$rule_id]]$formula,c$rule_id)
      !is.na(d$degree)&&(d$zero||d$degree==1L)
    },logical(1))
    if(!all(proven)){missing <- 'customs_value';next}
    ids <- vapply(applied,`[[`,character(1),'rule_id')
    values[[mapping[[authority]]]] <- exact_sum(ids)
  }
  homogeneous <- stable(matched)&&all(vapply(Filter(function(c)identical(c$status,'applied'),result$components),function(c) {
    d <- proof$value(rules[[c$rule_id]]$formula,c$rule_id)
    !is.na(d$degree)&&(d$zero||d$degree==1L)
  },logical(1)))
  values$statutory_total_rate <- if(identical(result$status,'complete')&&homogeneous)result$complete_total else NA_real_
  if(!homogeneous&&identical(result$status,'complete'))missing <- 'customs_value'
  additional <- vapply(Filter(function(c)c$authority!='base'&&c$status=='applied',result$components),`[[`,character(1),'rule_id')
  values$statutory_total_additional <- if(!is.na(values$statutory_total_rate)&&!is.na(values$statutory_base_rate))
    exact_sum(additional) else NA_real_
  attr(values,'missing_inputs') <- missing
  values
}

project_shipment_state <- function(rates,index,normalized_dir) {
  if(!nrow(rates))stop('Shipment projection requires a complete identified grid')
  if(anyDuplicated(rates[c('hts10','country')]))stop('Duplicate shipment identity in build state')
  profile <- list(id='unclaimed_missing_shipment_facts/v1',facts=list(customs_value=1,claims=list()),
    basis='USD1 reference customs value; no FTZ, use, content, quota, company, quantity or other shipment fact assumed')
  out <- rates
  for(name in intersect(c('duty_provenance_json','ch99_rules_json','s232_suppressed_json','pending_activation_json'),names(out))) {
    out[[paste0('aggregate_',name)]] <- out[[name]];out[[name]] <- NA_character_
  }
  stat_cols <- grep('^statutory_',names(out),value=TRUE)
  for(name in stat_cols) {
    out[[paste0('modeled_legacy_',name)]] <- out[[name]]
    out[[name]] <- if(is.numeric(out[[name]]))NA_real_ else NA_character_
  }
  # Old scalar codes also came from the aggregate's candidate selection. Keep
  # them explicitly as aggregate provenance; conditional/multiple codes live in
  # the resolved decisions and cannot be collapsed to one reporting heading.
  for(name in grep('^ch99_code_',names(out),value=TRUE)) {
    out[[paste0('aggregate_',name)]] <- out[[name]];out[[name]] <- NA_character_
  }
  out$shipment_status <- rep(NA_character_,nrow(out));out$shipment_decision_ids_json <- rep(NA_character_,nrow(out))
  out$shipment_missing_inputs_json <- rep(NA_character_,nrow(out));out$shipment_source_errors_json <- rep(NA_character_,nrow(out))
  out$shipment_exact_time_required <- rep(NA,nrow(out))
  class_keys <- rep('',nrow(rates));memberships <- list();classes <- list();projections <- list()
  for(entry in index$bundles) {
    b <- .shipment_verified_bundle(index,entry,normalized_dir);prepared <- prepare_shipment_bundle(b)
    if(!is.null(prepared$maps$error))stop('Invalid prepared shipment bundle: ',prepared$maps$error)
    if(any(!rates$hts10 %in% unlist(b$products))||any(!rates$country %in% unlist(b$countries)))stop('Wide row outside shipment bundle grid')
    at <- .shipment_time(entry$valid_from)
    # Group identical scope signatures before the product-country cross product.
    # Every group still executes the authoritative interpreter, with globally
    # addressable dependencies and the same facts. No economic column is read.
    scope_signature <- function(id,index,is_product) {
      env <- if(is_product)index$products else index$countries
      universal <- if(is_product)index$universal_p else index$universal_c
      hits <- if(exists(id,envir=env,inherits=FALSE))env[[id]] else integer()
      hits <- sort(unique(c(universal,hits)));hits <- hits[index$from[hits]<=at & at<index$until[hits]]
      paste(hits,collapse=',')
    }
    signature <- function(ids,is_product)vapply(ids,function(id)paste(
      scope_signature(id,prepared$rule_index,is_product),scope_signature(id,prepared$coverage_index,is_product),sep='/'),character(1))
    ps <- unique(rates$hts10);co <- unique(rates$country)
    p_signatures <- signature(ps,TRUE);c_signatures <- signature(co,FALSE)
    pg <- match(p_signatures,unique(p_signatures));cg <- match(c_signatures,unique(c_signatures))
    row_groups <- split(seq_len(nrow(rates)),paste(pg[match(rates$hts10,ps)],cg[match(rates$country,co)],sep='|'))
    row_class <- character(nrow(rates));cache <- new.env(hash=TRUE,parent=emptyenv())
    for(rows in row_groups) {
      p <- rates$hts10[rows[1]];c <- rates$country[rows[1]]
      rule_ids <- .shipment_index_matches(prepared$rule_index,p[1],c[1],at)
      coverage_ids <- .shipment_index_matches(prepared$coverage_index,p[1],c[1],at)
      key <- paste(paste(rule_ids,collapse=','),paste(coverage_ids,collapse=','),sep='/')
      if(!exists(key,envir=cache,inherits=FALSE)) {
        result <- evaluate_shipment_prepared(prepared,p[1],c[1],entry$valid_from,profile$facts)
        compact <- .shipment_compact_decision(result)
        id <- .shipment_source_signature(list(bundle_id=b$bundle_id,profile=profile,result=compact))
        cache[[key]] <- id;projections[[id]] <- .shipment_rate_projection(result,b)
        classes[[id]] <- data.frame(revision=index$revision,dataset_version=index$dataset_version,
          evidence_snapshot_id=index$evidence_snapshot_id,bundle_id=b$bundle_id,class_id=id,status=result$status,
          known_subtotal=result$known_subtotal,complete_total=result$complete_total %||% NA_real_,
          profile_json=.shipment_json(profile),decision_json=.shipment_json(compact),
          rate_projection_json=.shipment_json(projections[[id]]),
          projection_missing_inputs_json=.shipment_json(as.list(attr(projections[[id]],'missing_inputs'))),stringsAsFactors=FALSE)
      }
      # Vectorized product/country membership avoids one interpreter call per
      # wide row. This assignment covers only the exact signature pair.
      row_class[rows] <- cache[[key]]
    }
    if(any(!nzchar(row_class)))stop('Incomplete shipment decision membership')
    memberships[[length(memberships)+1L]] <- data.frame(revision=index$revision,hts10=rates$hts10,country=rates$country,
      dataset_version=index$dataset_version,bundle_id=b$bundle_id,class_id=row_class,entry_valid_from=entry$valid_from,
      entry_valid_until=entry$valid_until,stringsAsFactors=FALSE)
    class_keys <- ifelse(nzchar(class_keys),paste(class_keys,row_class,sep='|'),row_class)
  }
  for(key in unique(class_keys)) {
    ids <- unique(strsplit(key,'|',fixed=TRUE)[[1]]);rows <- which(class_keys==key)
    for(name in names(projections[[ids[1]]])) {
      xs <- vapply(projections[ids],function(p)p[[name]],numeric(1))
      if(all(!is.na(xs))&&length(unique(xs))==1L)out[[name]][rows] <- xs[1]
    }
    decisions <- lapply(classes[ids],function(c)jsonlite::fromJSON(c$decision_json,simplifyVector=FALSE))
    statuses <- vapply(decisions,`[[`,character(1),'status')
    status <- if(any(statuses=='unresolved_source'))'unresolved_source' else if(any(statuses=='needs_inputs'))'needs_inputs' else 'complete'
    missing <- sort(unique(c(unlist(lapply(decisions,`[[`,'missing_inputs')),
      unlist(lapply(projections[ids],attr,'missing_inputs')))))
    if(status=='complete'&&is.na(out$statutory_total_rate[rows[1]])) {
      status <- 'needs_inputs';missing <- sort(unique(c(missing,if(length(ids)>1L)'entry_at' else 'customs_value')))
    }
    out$shipment_status[rows] <- status
    out$shipment_decision_ids_json[rows] <- .shipment_json(as.list(ids))
    out$shipment_missing_inputs_json[rows] <- .shipment_json(as.list(missing))
    out$shipment_source_errors_json[rows] <- .shipment_json(as.list(sort(unique(unlist(lapply(decisions,`[[`,'source_errors'))))))
    out$shipment_exact_time_required[rows] <- length(ids)>1L
  }
  out$shipment_dataset_version <- index$dataset_version;out$shipment_evidence_snapshot_id <- index$evidence_snapshot_id
  out$shipment_contract_version <- 'sail.shipment-result/v1'
  out$shipment_projection_version <- 'sail.shipment-wide/v1'
  out$shipment_bundle_ids_json <- .shipment_json(lapply(index$bundles,`[[`,'bundle_id'))
  out$shipment_quote_profile <- profile$id
  list(rates=out,memberships=dplyr::bind_rows(memberships),classes=dplyr::bind_rows(classes))
}

mark_shipment_contract_unavailable <- function(rates,reason) {
  for(name in intersect(c('duty_provenance_json','ch99_rules_json','s232_suppressed_json','pending_activation_json'),names(rates))) {
    rates[[paste0('aggregate_',name)]] <- rates[[name]];rates[[name]] <- NA_character_
  }
  for(name in grep('^statutory_',names(rates),value=TRUE)) {
    rates[[paste0('modeled_legacy_',name)]] <- rates[[name]]
    rates[[name]] <- if(is.numeric(rates[[name]]))NA_real_ else NA_character_
  }
  for(name in grep('^ch99_code_',names(rates),value=TRUE)) {
    rates[[paste0('aggregate_',name)]] <- rates[[name]];rates[[name]] <- NA_character_
  }
  rates$shipment_status <- 'unresolved_source';rates$shipment_contract_version <- 'unsupported_or_incomplete_contract'
  rates$shipment_projection_version <- 'sail.shipment-wide/v1'
  rates$shipment_source_errors_json <- .shipment_json(list(reason));rates$shipment_dataset_version <- NA_character_
  rates$shipment_evidence_snapshot_id <- NA_character_;rates$shipment_decision_ids_json <- NA_character_
  rates$shipment_bundle_ids_json <- NA_character_;rates$shipment_missing_inputs_json <- NA_character_
  rates$shipment_quote_profile <- NA_character_;rates$shipment_exact_time_required <- NA
  rates
}
