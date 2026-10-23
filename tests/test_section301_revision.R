suppressPackageStartupMessages(source('src/helpers.R'))
source('src/section301_revision.R')
source('src/resolve_shipment_duties.R')
out <- tempfile('s301-test-');dir.create(out)
status <- system2('python3','tests/python/test_section301_sources.py',
  env=paste0('S301_TEST_OUTPUT=',shQuote(out)))
stopifnot(status==0)
old <- jsonlite::fromJSON(file.path(out,'2025_basic.json'),simplifyVector=FALSE)
new <- jsonlite::fromJSON(file.path(out,'2026_rev_21.json'),simplifyVector=FALSE)
mar <- jsonlite::fromJSON(file.path(out,'2025_rev_27.json'),simplifyVector=FALSE)
retro <- jsonlite::fromJSON(file.path(out,'2026_rev_11.json'),simplifyVector=FALSE)
at <- '2026-10-22T12:00:00-04:00'
all <- s301_revision_matches(new$extraction,unlist(new$products),at)
lookup <- s301_revision_lookup(all)
stopifnot(!anyDuplicated(lookup$hts10))
rate <- function(code) { value<-lookup$blanket_301[lookup$hts10==code];stopifnot(length(value)==1);value }
stopifnot(rate('6307909891')==.075,rate('6307909870')==.5,
  rate('8542310015')==.5,rate('4015121010')==1)
old_lookup <- s301_revision_lookup(s301_revision_matches(old$extraction,unlist(old$products),'2025-01-02T12:00:00-05:00'))
stopifnot(old_lookup$blanket_301[old_lookup$hts10=='4015121010']==.5)

# Complete source matching is not a complete tariff stack. Fragment compilation
# does not attest unimplemented authority/claim coverage.
f <- compile_s301_revision_fragment(new$extraction,unlist(new$products))
stopifnot(length(f$coverage)==0,length(f$rules)>10)
b <- list(contract_version='sail.shipment-rules/v1',dataset_version='test-source-reconstruction',
  evidence_snapshot_id='source-test',revision='2026_rev_21',valid_from='2026-10-09T00:00:00-04:00',
  valid_until='2026-10-23T00:00:00-04:00',products=new$products,countries=list('5700','1220'),
  coverage_requirements=list('section_301'),rules=f$rules,sources=f$sources,
  fact_definitions=f$fact_definitions,coverage=list())
evaluate <- function(code,facts=list(customs_value=100),country='5700',bundle=b)
  .evaluate_shipment_bundle(bundle,code,country,at,facts)
source('src/compile_shipment_rules.R')
beyond <- b;beyond$valid_until <- '2026-11-01T00:00:00-05:00'
stopifnot(inherits(try(compose_shipment_rules(beyond,list(f)),silent=TRUE),'try-error'))
r <- evaluate('6307909891')
stopifnot(r$known_subtotal==7.5,is.null(r$complete_total),r$status=='unresolved_source')
stopifnot(evaluate('8542310015')$known_subtotal==50,evaluate('6307909891',country='1220')$known_subtotal==0,
  'product_not_valid_in_revision' %in% evaluate('8542310000')$source_errors)
r <- evaluate('6307909870');stopifnot(length(r$missing_inputs)==1,r$known_subtotal==0)
facts <- list(customs_value=100);facts[[r$missing_inputs[1]]] <- TRUE
stopifnot(evaluate('6307909870',facts)$known_subtotal==50)
facts[[r$missing_inputs[1]]] <- FALSE
stopifnot(evaluate('6307909870',facts)$known_subtotal==0)

# Action order, duplicated source, and aggregate modeling fields cannot change
# a shipment amount. A conflicting legal action is not resolved with MAX().
changed <- b;changed$rules <- rev(b$rules);changed$sources <- c(b$sources,b$sources)
stopifnot(evaluate('6307909891',bundle=changed)$known_subtotal==7.5)
facts <- list(customs_value=100,modeled_s301_scope_share=0,assembly_credit=999)
stopifnot(evaluate('6307909891',facts)$known_subtotal==7.5)
x <- new$extraction; duplicate <- x$actions[[1]];duplicate$reporting_code <- '9903.91.99'
x$actions <- c(x$actions,list(duplicate))
stopifnot(inherits(try(s301_revision_matches(x,unlist(new$products),at),silent=TRUE),'try-error'))

# Explicit time limits remain executable, including the midnight/00:01 gap.
f_old <- compile_s301_revision_fragment(old$extraction,unlist(old$products))
r_old <- Filter(function(r) '9903.91.04' %in% unlist(r$reporting_codes),f_old$rules)[[1]]
stopifnot(!.shipment_scope(r_old$scope,'6307909870','5700',.shipment_time('2025-01-01T00:00:59-05:00')),
  .shipment_scope(r_old$scope,'6307909870','5700',.shipment_time('2025-01-01T00:01:00-05:00')),
  !.shipment_scope(r_old$scope,'6307909870','5700',.shipment_time('2026-01-01T00:00:00-05:00')))

fm <- compile_s301_revision_fragment(mar$extraction,unlist(mar$products))
bm <- b;bm$revision <- '2025_rev_27';bm$products<-mar$products;bm$countries<-list('5700','5830','1220')
bm$valid_from<-'2025-11-08T00:00:00-05:00';bm$valid_until<-'2025-11-11T00:00:00-05:00'
bm$rules<-fm$rules;bm$sources<-fm$sources;bm$fact_definitions<-fm$fact_definitions
mf <- list(customs_value=100)
for(k in names(fm$fact_definitions)) if(fm$fact_definitions[[k]]$type=='boolean') mf[[k]]<-TRUE
mr <- function(country,when,facts=mf) .evaluate_shipment_bundle(bm,'8426190000',country,when,facts)
stopifnot(mr('5700','2025-11-09T12:00:00-05:00')$known_subtotal==125,
  mr('5830','2025-11-09T12:00:00-05:00')$known_subtotal==100,
  mr('5700','2025-11-10T00:01:00-05:00')$known_subtotal==25,
  mr('5830','2025-11-10T00:01:00-05:00')$known_subtotal==0,
  mr('5700','2025-11-09T00:30:00-04:00')$known_subtotal==25)
stopifnot(any(grepl('rule_source_unverified',unlist(mr('5700','2025-11-09T00:30:00-04:00')$source_errors))))
# Aggregate projection remains additive and preserves the cross-origin action.
stack <- apply_stacking_rules(tibble(hts10='8426190000',country=c('5700','5830'),
  base_rate=0,rate_301=c(.25,0),rate_s301_maritime=1))
stopifnot(identical(stack$total_additional,c(1.25,1)))
net <- compute_net_authority_contributions(stack)
stopifnot(identical(net$net_301,c(1.25,1)))
source('src/resolve_rate_normalized.R')
ex <- tibble(authority='section_301',hts10='8426190000',country=NA_character_,
  hts_prefix=NA_character_,program=NA_character_,exemption_share=1)
stopifnot(.compound_exemption_share(ex,'section_301','8426190000','5700','s301_maritime')==0,
  .compound_exemption_share(ex,'section_301','8426190000','5700','s301_revision_china')==1)
ex$program <- 's301_maritime'
stopifnot(.compound_exemption_share(ex,'section_301','8426190000','5700','s301_maritime')==1,
  .compound_exemption_share(ex,'section_301','8426190000','5700','s301_revision_china')==0)

# A source-derived fixture exercises the identical emitted rules in TypeScript
# and the stored API path. Only the test product universe is reduced.
fr <- compile_s301_revision_fragment(retro$extraction,unlist(retro$products))
br <- b;br$revision<-'2026_rev_11';br$products<-retro$products
br$valid_from<-'2026-07-01T00:00:00-04:00';br$valid_until<-'2026-07-21T00:00:00-04:00'
br$rules<-list();br$sources<-list();br$fact_definitions<-list()
br <- compose_shipment_rules(br,list(fr))
claim <- list(customs_value=100,claims=list('section301:9903.88.69'))
pump <- names(Filter(function(d) identical(d$description,'Pump casings and bodies'),br$fact_definitions))
stopifnot(length(pump)==1)
claimed_pump <- claim;claimed_pump[[pump]]<-TRUE
rr <- function(code,when='2026-07-02T12:00:00-04:00',facts=claim)
  .evaluate_shipment_bundle(br,code,'5700',when,facts)
stopifnot(rr('8483509040')$known_subtotal==0,
  rr('8483509040',facts=list(customs_value=100))$known_subtotal==25,
  length(rr('8413919039')$missing_inputs)>1,
  rr('8413919039',facts=claimed_pump)$known_subtotal==0,
  length(rr('8413919039',facts=claimed_pump)$missing_inputs)==0,
  rr('8413919039',when='2026-07-01T00:30:00-04:00',facts=list(customs_value=100))$known_subtotal==25,
  any(grepl('source_discrepancy',rr('8413919039',when='2026-07-01T00:30:00-04:00',facts=claimed_pump)$source_errors)))
shredder <- names(Filter(function(d) grepl('foregoing parts of metal shredders',d$description %||% ''),br$fact_definitions))
stopifnot(length(shredder)==1)
claimed_shredder<-claim;claimed_shredder[[shredder]]<-TRUE
stopifnot(rr('8479909591',facts=claimed_shredder)$known_subtotal==0)
effects <- s301_claim_effects_table(fr,'2026_rev_11')
stopifnot(nrow(effects)>0,!any(effects$target_reporting_code %in% c('9903.88.69','9903.88.70')),
  all(effects$rule_id %in% vapply(fr$rules,`[[`,character(1),'id')))
stopifnot(length(rr('8413919039',facts=list(customs_value=100))$claim_options)==1,
  rr('8413919039',facts=list(customs_value=100))$claim_options[[1]]$id=='section301:9903.88.69',
  length(evaluate('8542310015')$claim_options)==0)
# A model share does not change an exclusion; unknown claims stay unpriced.
modeled<-claimed_pump;modeled$modeled_s301_scope_share<-0;modeled$assembly_credit<-999
stopifnot(rr('8413919039',facts=modeled)$known_subtotal==0,
  any(grepl('claim_not_priced',rr('8413919039',facts=list(claims=list('unknown')))$source_errors)))
permuted<-fr;permuted$rules<-rev(fr$rules);permuted$sources<-c(rev(fr$sources),fr$sources)
permuted$relations<-c(rev(fr$relations),fr$relations)
seed<-br;seed$rules<-list();seed$sources<-list();seed$fact_definitions<-list();seed$claim_definitions<-list()
reordered<-compose_shipment_rules(seed,list(permuted))
stopifnot(identical(.shipment_canonical(.evaluate_shipment_bundle(reordered,'8413919039','5700',
  '2026-07-02T12:00:00-04:00',claimed_pump)),.shipment_canonical(rr('8413919039',facts=claimed_pump))))
bc<-bm;bc$rules<-list();bc$sources<-list();bc$fact_definitions<-list()
bc<-compose_shipment_rules(bc,list(fm))
crane_fact<-names(Filter(function(d) grepl('Importer certification:',d$description %||% '',fixed=TRUE),bc$fact_definitions))
stopifnot(length(crane_fact)==1)
crane_claim<-mf;crane_claim$claims<-list('section301:9903.91.09');crane_claim[[crane_fact]]<-TRUE
cr<-.evaluate_shipment_bundle(bc,'8426190000','5700','2025-11-09T12:00:00-05:00',crane_claim)
stopifnot(cr$known_subtotal==0,length(cr$suppressed_rules)==2)
crane_claim[[crane_fact]]<-FALSE
stopifnot(.evaluate_shipment_bundle(bc,'8426190000','5700','2025-11-09T12:00:00-05:00',crane_claim)$known_subtotal==125)
crane_claim[[crane_fact]]<-TRUE

reduce <- function(bundle,products) {
  bundle$products<-as.list(products)
  bundle$rules<-Filter(function(r) length(intersect(unlist(r$scope$hts_exact),products))>0,bundle$rules)
  bundle$rules<-lapply(bundle$rules,function(r){r$scope$hts_exact<-as.list(intersect(unlist(r$scope$hts_exact),products));r})
  ids<-vapply(bundle$rules,`[[`,character(1),'id')
  trim <- function(x) {
    if(!is.list(x)) return(x)
    if(!is.null(x$rule_applies) && !x$rule_applies %in% ids) return(list(value=FALSE))
    if(!is.null(x$rule_amount) && !x$rule_amount %in% ids) return(list(value=0))
    lapply(x,trim)
  }
  bundle$rules<-lapply(bundle$rules,trim)
  fact_keys<-character()
  collect<-function(x) {
    if(!is.list(x)) return(invisible(NULL))
    if(!is.null(x$fact)) fact_keys<<-c(fact_keys,x$fact)
    invisible(lapply(x,collect))
  }
  collect(bundle$rules)
  bundle$fact_definitions<-bundle$fact_definitions[sort(unique(fact_keys))]
  bundle$relation_decisions<-Filter(function(e) e$rule_id %in% ids &&
    (is.null(e$when_rule_applies) || e$when_rule_applies %in% ids),bundle$relation_decisions)
  bundle$claim_definitions<-lapply(bundle$claim_definitions,function(c){
    c$rule_ids<-as.list(intersect(unlist(c$rule_ids),ids))
    c$candidate_rule_ids<-as.list(intersect(unlist(c$candidate_rule_ids),ids));c})
  bundle
}
sf <- list(customs_value=100)
for(k in names(f$fact_definitions)) if(f$fact_definitions[[k]]$type=='boolean') sf[[k]]<-TRUE
case <- function(name,bundle,hts,country,entry,facts,amount) list(name=name,bundle=bundle,
  hts10=hts,country=country,entry_at=entry,facts=facts,
  expected=list(known_subtotal=amount,complete_total=NULL,status='unresolved_source'))
fixture <- list(bundles=list(current=reduce(b,c('6307909891','6307909870','8542310015')),
  maritime=reduce(bc,'8426190000'),exclusions=reduce(br,c('8483509040','8413919039','8479909591'))),cases=list(
  case('neighboring non-mask remains List 4A','current','6307909891','5700',at,list(customs_value=100),7.5),
  case('exact mask description established','current','6307909870','5700',at,sf,50),
  case('semiconductor heading rate','current','8542310015','5700',at,list(customs_value=100),50),
  case('technology-transfer origin does not broaden','current','6307909891','1220',at,sf,0),
  case('China crane cumulative investigations','maritime','8426190000','5700','2025-11-09T12:00:00-05:00',mf,125),
  case('Taiwan crane qualifying Chinese components or ownership','maritime','8426190000','5830','2025-11-09T12:00:00-05:00',mf,100),
  case('suspension retains earlier China investigation','maritime','8426190000','5700','2025-11-10T00:01:00-05:00',mf,25),
  case('suspension ends cross-origin maritime charge','maritime','8426190000','5830','2025-11-10T00:01:00-05:00',mf,0),
  case('ambiguous EDT wording does not inflate known subtotal','maritime','8426190000','5700','2025-11-09T00:30:00-04:00',mf,25),
  case('whole statistical line exclusion only when claimed','exclusions','8483509040','5700','2026-07-02T12:00:00-04:00',claim,0),
  case('unclaimed charge remains statutory','exclusions','8483509040','5700','2026-07-02T12:00:00-04:00',list(customs_value=100),25),
  case('retroactive pump code and alternative descriptions','exclusions','8413919039','5700','2026-07-02T12:00:00-04:00',claimed_pump,0),
  case('retroactive shredder code before publication','exclusions','8479909591','5700','2026-07-02T12:00:00-04:00',claimed_shredder,0),
  case('claimed amendment boundary remains unresolved','exclusions','8413919039','5700','2026-07-01T00:30:00-04:00',claimed_pump,0),
  case('crane contract exclusion removes both named investigations','maritime','8426190000','5700','2025-11-09T12:00:00-05:00',crane_claim,0)))
destination <- Sys.getenv('S301_CONFORMANCE_OUTPUT','')
if(nzchar(destination)) jsonlite::write_json(fixture,destination,auto_unbox=TRUE,pretty=TRUE,null='null',digits=NA)
committed <- 'tests/fixtures/shipment/section301-reconstruction.json'
if(!nzchar(destination) && file.exists(committed)) stopifnot(identical(.shipment_canonical(fixture),
  .shipment_canonical(jsonlite::fromJSON(committed,simplifyVector=FALSE))))
unlink(out,recursive=TRUE)
cat('Section 301 source reconstruction, full revision scope, temporal and shipment checks passed\n')
