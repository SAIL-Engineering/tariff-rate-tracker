# Ordinary IEEPA country-action selection, independent of product/claim
# evaluation and model weights. EO 14266 secs. 2-3 suspends named headings;
# it does not change the rates printed on those suspended headings. The
# operative baseline is a separate action (9903.01.25).

load_ieepa_country_amendments <- function(root=here::here()) {
  out <- tempfile(fileext='.json');on.exit(unlink(out),add=TRUE)
  status <- system2('python3',c(shQuote(file.path(root,'src/ieepa_amendments.py')),shQuote(out)))
  if(status!=0L) stop('IEEPA amendment extraction failed; historical replacements unresolved')
  jsonlite::fromJSON(out,simplifyVector=FALSE)
}

apply_ieepa_country_amendments <- function(rows,country_lookup,effective_date,
                                          amendments=load_ieepa_country_amendments()) {
  if(is.null(effective_date)) return(rows)
  for(col in c('amendment_source_id','amendment_source_sha256','amendment_effective_from'))
    if(!col %in% names(rows)) rows[[col]] <- rep(NA_character_,nrow(rows))
  # This adapter calculates a daily aggregate. Exact 00:01 Eastern entry
  # boundaries are retained in the evidence for the shipment interpreter.
  active <- Filter(function(a) as.Date(substr(a$effective_from,1,10))<=as.Date(effective_date),amendments)
  for(a in active) {
    old <- rows$ch99_code %in% unlist(a$terminated_codes)
    rows$terminated[old] <- TRUE
    rows$amendment_source_id[old] <- a$source$id
    rows$amendment_source_sha256[old] <- a$source$sha256
    rows$amendment_effective_from[old] <- a$effective_from
    for(action in a$actions) {
      native <- rows[rows$ch99_code==action$ch99_code,]
      if(nrow(native)) {
        if(any(native$rate!=action$rate|native$rate_type!=action$rate_type,na.rm=TRUE))
          stop('Conflicting native and retroactive IEEPA formula: ',action$ch99_code)
        next
      }
      country <- match_countries(action$country_name,country_lookup)
      if(anyNA(country$census_code)) stop('Unresolved amendment origin')
      rows <- dplyr::bind_rows(rows,tibble::tibble(ch99_code=action$ch99_code,rate=action$rate,
        rate_type=action$rate_type,phase='phase2_aug7',terminated=FALSE,
        country_name=country$country_name,census_code=country$census_code,
        source_description=action$source_description,duty_expression=action$duty_expression,
        source_heading_sha256=action$source_heading_sha256,
        amendment_source_id=a$source$id,amendment_source_sha256=a$source$sha256,
        amendment_effective_from=a$effective_from))
    }
  }
  attr(rows,'amendment_sources') <- lapply(active,`[[`,'source')
  rows
}

ieepa_heading_terminated <- function(description, effective_date=NULL) {
  flat <- gsub('<[^>]+>',' ',description)
  flat <- gsub('[[:space:]\u00a0]+',' ',flat)
  terminated <- grepl('provision(?: was| is| has been)? (?:temporarily )?(?:terminated|suspended)',
    flat,ignore.case=TRUE,perl=TRUE)
  if(!terminated || is.null(effective_date)) return(terminated)
  at <- stringr::str_match(flat,stringr::regex(
    'provision(?: was| is| has been)? (?:temporarily )?(?:terminated|suspended) (?:on|as of) ([A-Za-z]+ [0-9]{1,2}, [0-9]{4})',ignore_case=TRUE))[,2]
  if(!is.na(at)) {
    day <- as.Date(at,format='%B %d, %Y')
    if(is.na(day)) stop('Invalid IEEPA termination date')
    return(as.Date(effective_date)>=day)
  }
  TRUE
}

ieepa_universal_baseline <- function(hts_raw) {
  items <- Filter(function(r) identical(r$htsno,'9903.01.25'),hts_raw)
  if(!length(items)) return(NULL)
  expressions <- unique(vapply(items,function(r) r$general %||% '',character(1)))
  if(length(expressions)!=1L) stop('Conflicting universal reciprocal expressions')
  found <- stringr::str_match(expressions,'\\+\\s*([0-9.]+)%')[,2]
  if(is.na(found)) stop('Unresolved universal reciprocal expression')
  as.numeric(found)/100
}

ieepa_reciprocal_country_exclusions <- function(hts_raw,country_lookup) {
  # 9903.01.25 expressly excepts .26-.33. The country exclusions are
  # separate published provisions, not a missing country-rate lookup.
  items <- Filter(function(r) r$htsno %in% c('9903.01.26','9903.01.27','9903.01.29'),hts_raw)
  dplyr::bind_rows(lapply(items,function(r) {
    description <- r$description %||% ''
    gn3b <- grepl('general note 3\\(b\\)',description,ignore.case=TRUE)
    if(gn3b) {
      country <- NA_character_
    } else {
      if(!identical(trimws(r$general %||% ''),'The duty provided in the applicable subheading'))
        stop('Unresolved reciprocal country-exclusion expression: ',r$htsno)
      matched <- match_countries(extract_countries_from_description(description),country_lookup)
      if(nrow(matched)!=1L || anyNA(matched$census_code))
        stop('Unresolved reciprocal country-exclusion scope: ',r$htsno)
      country <- matched$census_code
    }
    tibble::tibble(census_code=country,ch99_code=r$htsno,gn3b=gn3b,
      source_description=description,duty_expression=r$general %||% '',
      source_heading_sha256=digest::digest(jsonlite::toJSON(r,auto_unbox=TRUE,null='null'),
        algo='sha256',serialize=FALSE))
  }))
}

select_ieepa_country_actions <- function(extracted,countries,excluded_countries) {
  baseline <- attr(extracted,'universal_baseline')
  exclusions <- attr(extracted,'country_exclusions')
  required <- c('ch99_code','rate','rate_type','phase','terminated','census_code')
  if(!all(required %in% names(extracted))) stop('Incomplete IEEPA extraction contract')
  empty <- tibble(census_code=character(),ieepa_country_rate=numeric(),
    country_eo_rate=numeric(),country_eo_ch99=character(),ieepa_recip_ch99=character(),ieepa_type=character(),
    is_universal_baseline_country=logical(),is_reciprocal_country_excluded=logical(),
    ieepa_selected_actions_json=character())
  if(!nrow(extracted) && is.null(baseline)) return(empty)
  if(!is.null(baseline) && (length(baseline)!=1L || !is.finite(baseline) || baseline<0))
    stop('Invalid IEEPA baseline parameter')
  if(any(!extracted$terminated & (is.na(extracted$rate_type) |
      (extracted$rate_type!='passthrough' & is.na(extracted$rate)))))
    stop('Missing active IEEPA rate parameter')
  if(!is.null(exclusions) && nrow(exclusions) &&
     any(!is.na(exclusions$census_code) & !exclusions$census_code %in% excluded_countries))
    stop('Reciprocal country exclusions disagree with the published scope')
  # Future-effective rows are filtered by the extractor's source date gate.
  # Retained suspended rows are evidence, never substitutes for the baseline.
  live <- extracted %>% filter(!terminated,!is.na(rate),!is.na(census_code)) %>%
    distinct(census_code,ch99_code,rate,rate_type,phase)
  if(any(!is.finite(live$rate)|live$rate<0)) stop('Invalid IEEPA action rate')
  live$action_group <- ifelse(live$phase=='country_eo','country_eo','reciprocal')
  conflict <- live %>% count(census_code,action_group) %>% filter(n>1)
  if(nrow(conflict)) stop('Unresolved overlapping IEEPA actions: ',paste(conflict$census_code,collapse=', '))
  if(any(live$rate_type[live$action_group=='country_eo']!='surcharge')) stop('Country EO requires a separate reviewed formula')
  rec <- live %>% filter(action_group=='reciprocal',!census_code %in% excluded_countries)
  eo <- live %>% filter(action_group=='country_eo')
  rows <- lapply(sort(unique(countries)),function(country) {
    r <- rec[rec$census_code==country,];e <- eo[eo$census_code==country,]
    excluded <- country %in% excluded_countries
    exclusion_code <- NA_character_
    if(excluded) {
      if(is.null(exclusions)||!nrow(exclusions)) stop('Missing reciprocal country-exclusion evidence')
      ex <- exclusions[!is.na(exclusions$census_code) & exclusions$census_code==country,]
      # The caller supplies the revision's GN 3(b) membership, not a fixed
      # origin list. Its exclusion heading must still exist in this source.
      if(!nrow(ex)) ex <- exclusions[exclusions$gn3b,]
      if(nrow(ex)!=1L) stop('Missing or conflicting reciprocal country-exclusion evidence: ',country)
      exclusion_code <- ex$ch99_code
    }
    use_baseline <- !nrow(r) && !country %in% excluded_countries && !is.null(baseline)
    if(!nrow(r) && !use_baseline && !excluded)
      stop('Missing reciprocal action or baseline for origin: ',country)
    rec_rate <- if(nrow(r)) r$rate else if(use_baseline) baseline else 0
    eo_rate <- if(nrow(e)) e$rate else 0
    rec_code <- if(nrow(r)) r$ch99_code else if(use_baseline) '9903.01.25' else exclusion_code
    eo_code <- if(nrow(e)) e$ch99_code else NA_character_
    tibble(census_code=country,ieepa_country_rate=rec_rate+eo_rate,
      country_eo_rate=eo_rate,country_eo_ch99=eo_code,
      ieepa_recip_ch99=rec_code,ieepa_type=if(nrow(r)) r$rate_type else if(excluded) 'passthrough' else 'surcharge',
      is_universal_baseline_country=use_baseline,
      is_reciprocal_country_excluded=excluded,
      ieepa_selected_actions_json=as.character(jsonlite::toJSON(sort(na.omit(c(rec_code,eo_code))))))
  })
  if(!length(rows)) return(empty)
  bind_rows(rows)
}

# Evaluate the two legal actions separately. An Annex II / framework
# exemption of the reciprocal action cannot remove a different emergency
# action. Model-only duty-free treatment is explicitly separate.
ieepa_reciprocal_increment <- function(rate,type,base,exempt=FALSE) {
  inputs <- list(rate=rate,type=type,base=base,exempt=exempt)
  sizes <- lengths(inputs)
  if(any(sizes==0L)) return(numeric())
  n <- max(sizes)
  if(any(!sizes %in% c(1L,n))) stop('Inconsistent IEEPA parameter vector lengths')
  inputs <- lapply(inputs,rep_len,length.out=n)
  rate <- inputs$rate;type <- inputs$type;base <- inputs$base;exempt <- inputs$exempt
  invalid <- !is.na(rate) & !type %in% c('surcharge','floor','passthrough')
  if(any(invalid)) stop('Unresolved IEEPA duty expression')
  ifelse(exempt,0,ifelse(is.na(rate),NA_real_,
    ifelse(type=='floor',pmax(0,rate-base),ifelse(type=='surcharge',rate,0))))
}

ieepa_action_components <- function(total_rate,eo_rate,type,base,
                                   reciprocal_exempt=FALSE,eo_exempt=FALSE,modeled_duty_free=FALSE) {
  reciprocal <- ieepa_reciprocal_increment(total_rate-eo_rate,type,base,reciprocal_exempt)
  n <- length(reciprocal)
  country_eo <- ifelse(rep_len(eo_exempt,n),0,rep_len(eo_rate,n))
  data.frame(reciprocal=ifelse(rep_len(modeled_duty_free,n),0,reciprocal),
    country_eo=ifelse(rep_len(modeled_duty_free,n),0,country_eo))
}

# Evidence is separate from ordinary aggregate selection and does not certify
# product/claim eligibility. Persist retired headings as well as selected ones.
ieepa_action_decisions <- function(rows,selected,revision,root=here::here()) {
  fields <- c('revision','authority','country','ch99_code','rate_type','phase','decision',
    'source_description','duty_expression','source_heading_sha256','hts_sha256',
    'amendment_source_id','amendment_source_sha256','amendment_effective_from')
  empty <- as.data.frame(setNames(rep(list(character()),length(fields)),fields))
  empty$rate <- numeric(); empty$terminated <- logical()
  if((is.null(rows)||!nrow(rows))&&(is.null(selected)||!nrow(selected))) return(empty)
  hts <- file.path(root,'data/hts_archives',paste0('hts_',revision,'.json'))
  if(!file.exists(hts)) stop('Missing IEEPA revision evidence')
  if(!is.null(selected)) {
    excluded <- selected[selected$is_reciprocal_country_excluded %in% TRUE,]
    if(nrow(excluded)) {
      evidence <- attr(rows,'country_exclusions')
      if(is.null(evidence)) stop('Missing selected country-exclusion evidence')
      for(i in seq_len(nrow(excluded))) {
        native <- evidence[evidence$ch99_code==excluded$ieepa_recip_ch99[i],]
        if(nrow(native)!=1L) stop('Ambiguous selected country-exclusion evidence')
        rows <- dplyr::bind_rows(rows,tibble::tibble(census_code=excluded$census_code[i],
          ch99_code=native$ch99_code,rate=0,rate_type='passthrough',phase='country_exclusion',terminated=FALSE,
          source_description=native$source_description,duty_expression=native$duty_expression,
          source_heading_sha256=native$source_heading_sha256))
      }
    }
    baselines <- selected[selected$is_universal_baseline_country,]
    if(nrow(baselines)) {
      native <- Filter(function(r) identical(r$htsno,'9903.01.25'),jsonlite::fromJSON(hts,simplifyVector=FALSE))
      if(length(native)!=1) stop('Missing or ambiguous baseline evidence')
      r <- native[[1]]
      rows <- dplyr::bind_rows(rows,tibble::tibble(census_code=baselines$census_code,
        ch99_code='9903.01.25',rate=attr(rows,'universal_baseline'),rate_type='surcharge',
        phase='universal_baseline',terminated=FALSE,source_description=r$description,duty_expression=r$general,
        source_heading_sha256=digest::digest(jsonlite::toJSON(r,auto_unbox=TRUE,null='null'),algo='sha256',serialize=FALSE)))
    }
  }
  rows$revision <- revision;rows$authority <- 'ieepa_reciprocal';rows$country <- rows$census_code
  rows$hts_sha256 <- digest::digest(file=hts,algo='sha256')
  keys <- character()
  if(!is.null(selected)&&nrow(selected)) keys <- c(paste(selected$census_code,selected$ieepa_recip_ch99),
    paste(selected$census_code,selected$country_eo_ch99))
  rows$decision <- ifelse(rows$terminated,'retired_heading',
    ifelse(paste(rows$census_code,rows$ch99_code) %in% keys,'ordinary_action_selected','published_candidate'))
  for(col in setdiff(fields,names(rows))) rows[[col]] <- rep(NA_character_,nrow(rows))
  unique(as.data.frame(rows[,names(empty)]))
}

ieepa_evidence_fragment <- function(rows,revision,root=here::here()) {
  hts <- file.path(root,'data/hts_archives',paste0('hts_',revision,'.json'))
  if(!file.exists(hts)) stop('Missing IEEPA evidence artifact')
  id <- paste0('USITC-',revision,'-ieepa-headings')
  h <- digest::digest(file=hts,algo='sha256')
  sources <- list(list(id=id,status='verified',sha256=h,
    url=paste0('https://hts.usitc.gov/reststop/exportList?release=',build_release_name(revision),'&exportFormat=JSON'),
    citation=paste0('USITC ',revision,' Chapter 99 IEEPA headings; ordinary action evidence, not full legal coverage')))
  artifacts <- list(list(source_id=id,path=normalizePath(hts),sha256=h))
  for(s in attr(rows,'amendment_sources')) {
    sources[[length(sources)+1L]] <- list(id=s$id,status='verified',sha256=s$sha256,url=s$url,citation=s$citation)
    artifacts[[length(artifacts)+1L]] <- list(source_id=s$id,
      path=normalizePath(file.path(root,'resources/legal_evidence',sub('^FR-','',s$id),'notice.txt')),sha256=s$sha256)
  }
  list(contract_version='sail.shipment-rule-fragment/v1',id=paste0('ieepa-evidence-',revision),
    sources=sources,source_artifacts=artifacts,rules=list(),coverage=list(),fact_definitions=list())
}
