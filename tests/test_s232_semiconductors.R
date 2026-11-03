source('src/compile_shipment_rules.R')
source('src/section232_semiconductors.R')
products <- c('8471500150','8473301180','8471410150','8542310000')
fragment <- compile_s232_semiconductors_fragment('2026_rev_21', products)
base <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
base$revision <- '2026_rev_21';base$dataset_version <- 'semiconductor-history-regression'
base$products <- as.list(products);base$countries <- as.list(c('5700','2010','4280','5330','3510'))
base$valid_from <- fragment$supported_from;base$valid_until <- fragment$supported_until
base$rules <- list();base$claim_definitions <- list();base$fact_definitions <- list()
base$coverage <- list();base$coverage_requirements <- as.list(c('base','section_232','section_301','ieepa_fentanyl','section_122','section_338','adcvd'))
synthetic_source <- list(id='synthetic-semiconductor-history',status='verified',sha256=paste(rep('0',64),collapse=''),
  url='https://example.invalid/semiconductor-history',citation='Synthetic independent action, used only to exercise source-derived suppression edges')
base$sources <- c(base$sources,list(synthetic_source))
competitors <- c('9903.81.94','9903.82.17','9903.82.18','9903.82.26','9903.94.66','9903.01.77','9903.01.84','9903.88.03')
for(i in seq_along(competitors)) base$rules[[i]] <- list(id=paste0('synthetic-',i),action_id=paste0('synthetic-',i),
  authority='synthetic',kind='duty',verification='verified',source_ids=list(synthetic_source$id),
  scope=list(hts_exact=as.list(products)),reporting_codes=list(competitors[i]),formula=list(value=1))
base$rules[[8]]$authority <- 'section_301'
base$rules[[8]]$exclusion_claim_id <- 'synthetic-investigation-specific-exclusion'
base$rules[[8]]$formula <- list(op='if',args=list(list(claim='SYNTHETIC_301_EXCLUSION'),list(value=0),list(value=1)))
base$claim_definitions <- list(list(id='SYNTHETIC_301_EXCLUSION',label='Synthetic independent Section 301 exclusion',
  source_ids=list(synthetic_source$id),candidate_rule_ids=list('synthetic-8'),
  rule_ids=as.list(paste0('synthetic-',seq_along(competitors)))))
bundle <- compose_shipment_rules(base,list(fragment))
q <- list(customs_value=100,contains_logic_integrated_circuit=TRUE,all_logic_ic_specs_reviewed=TRUE,
  total_processing_performance=15000,dram_bandwidth_gb_s=4700,semiconductor_end_use='none',ieepa_ftz_entry=FALSE)
cases <- list()
add <- function(name,at,subtotal,suppressed=character(),facts=q,hts10=products[1],country='5700',missing=character(),error=NULL,code='9903.79.01') {
  result <- evaluate_shipment_bundle(bundle,hts10,country,at,facts)
  codes <- sort(unique(unlist(lapply(Filter(function(c)c$authority=='section_232' && c$status=='applied',result$components),`[[`,'reporting_codes'))))
  expected_suppressed <- if(length(suppressed))paste0('synthetic-',match(suppressed,competitors)) else character()
  okay <- abs(result$known_subtotal-subtotal)<1e-9 && setequal(result$suppressed_rules,expected_suppressed) &&
    setequal(result$missing_inputs,missing) && is.null(result$complete_total) && setequal(codes,code)
  if(!okay){print(list(case=name,codes=codes,result=result[c('known_subtotal','missing_inputs','suppressed_rules','source_errors')]));stop('Semiconductor regression')}
  if(!is.null(error))stopifnot(any(grepl(error,result$source_errors,fixed=TRUE)))
  cases[[length(cases)+1L]] <<- list(name=name,hts10=hts10,country=country,entry_at=at,facts=facts,
    expected=list(known_subtotal=subtotal,missing_inputs=as.list(result$missing_inputs),source_errors=as.list(result$source_errors),
      suppressed_rules=as.list(result$suppressed_rules),codes=as.list(codes),status=result$status,complete_total=NULL))
}
jan <- c('9903.81.94','9903.01.77','9903.01.84')
apr <- c('9903.82.17','9903.01.77','9903.01.84')
apr23 <- c(apr,'9903.82.18');may <- c(apr23,'9903.94.66');june <- c(may,'9903.82.26')
add('before original effective minute','2026-01-15T00:00:59-05:00',8,code=character())
add('original exact minute','2026-01-15T00:01:00-05:00',30,jan)
add('before April replacement','2026-04-06T00:00:59-04:00',30,jan)
add('April replacement exact minute','2026-04-06T00:01:00-04:00',30,apr)
add('April23 literal EST before instant','2026-04-23T01:00:59-04:00',30,apr)
add('April23 literal EST exact instant','2026-04-23T01:01:00-04:00',29,apr23)
add('Taiwan references before retroactive amendment','2026-05-01T00:00:59-04:00',29,apr23)
add('Taiwan references exact amendment instant','2026-05-01T00:01:00-04:00',28,may)
add('June future reversal is not active','2026-06-08T00:00:59-04:00',28,may)
add('June exact instant','2026-06-08T00:01:00-04:00',27,june)
for(country in unlist(base$countries)) add(paste('all origins',country),'2026-07-01T12:00:00-04:00',27,june,country=country)
for(hts in products[1:2]) add(paste('precise scope',hts),'2026-07-01T12:00:00-04:00',27,june,hts10=hts)
for(hts in products[3:4]) add(paste('uncovered neighbor',hts),'2026-07-01T12:00:00-04:00',8,hts10=hts,
  facts=structure(list(),names=character()),code=character())
f <- q;f$semiconductor_end_use <- 'us_civil_industrial'
add('industrial use revives independent duties','2026-07-01T12:00:00-04:00',8,facts=f,code='9903.79.08')
f <- q;f$customs_value <- NULL
add('missing value cannot revive displaced duties','2026-07-01T12:00:00-04:00',2,june,facts=f,missing='customs_value',code=character())
f <- q;f$ieepa_ftz_entry <- NULL
add('missing FTZ history cannot suppress independent duties','2026-07-01T12:00:00-04:00',2,facts=f,missing='ieepa_ftz_entry',code=character())
f$ieepa_ftz_entry <- TRUE
add('FTZ branch is unresolved before priority','2026-07-01T12:00:00-04:00',2,facts=f,error='semiconductor_ftz_admission_status',code=character())
f <- q;f$modeled_semi_qualifying_share <- 0;f$metal_share <- .01;f$assembly_credit <- 100
add('model changes cannot alter shipment liability','2026-07-01T12:00:00-04:00',27,june,facts=f)
f <- q;f$claims <- list('USMCA')
add('USMCA leaves semiconductor charge additive','2026-07-01T12:00:00-04:00',25,facts=f,error='claim_not_priced:USMCA:synthetic-')
f <- q;f$claims <- list('CHAPTER_98');f$chapter98_provision <- '98020060';f$chapter98_properly_claimed <- TRUE
add('Chapter98 explicit full value exception','2026-07-01T12:00:00-04:00',25,facts=f,error='claim_not_priced:CHAPTER_98:synthetic-')
f$chapter98_provision <- '98020080'
add('other Chapter98 terms must precede priority','2026-07-01T12:00:00-04:00',0,facts=f,error='semiconductor_chapter98_selected_provision',code=character())
f <- q;f$claims <- list('SYNTHETIC_301_EXCLUSION')
add('independent 301 exclusion does not waive semiconductor duty','2026-07-01T12:00:00-04:00',26,june,facts=f)
add('after source cutoff',fragment$supported_until,0,code=character(),error='outside_bundle_interval')
if('--emit' %in% commandArgs(trailingOnly=TRUE)) {
  file <- gzfile('tests/fixtures/shipment/semiconductor-history.json.gz','w')
  writeLines(jsonlite::toJSON(list(bundles=list(history=bundle),cases=lapply(cases,function(c){c$bundle<-'history';c})),
    auto_unbox=TRUE,null='null',digits=NA),file)
  close(file)
}
cat(length(cases),'semiconductor amendment, valuation and priority cases passed\n')
