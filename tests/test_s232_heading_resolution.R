suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R')
source('src/section232_revision.R')
source('src/compile_shipment_rules.R')
x <- load_s232_note16_source('2026_rev_21')
products <- c('7318158085','8415908010','8427104090','7616995160','7308200035','8403100000','8473301180','7616995161')
fragment <- compile_s232_note16_fragment(x,products)
base <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
base$rules <- list(); base$coverage <- list();base$claim_definitions <- list();base$fact_definitions <- list()
base$products <- as.list(products);base$countries <- as.list(as.character(read.csv('resources/census_codes.csv')$Code))
base$valid_from <- fragment$supported_from;base$valid_until <- fragment$supported_until
base$coverage_requirements <- list('section_232','base')
base$dataset_version <- 'note16-source-regression-not-a-release'
base$revision <- x$revision
bundle <- compose_shipment_rules(base,list(fragment))
cases <- list()
add <- function(name,hts,country,facts,subtotal,codes=character(),missing=character(),source_error=NULL,reporting=NULL) {
  # These fixtures describe ordinary entries; FTZ capability is tested separately.
  if(is.null(facts$ieepa_ftz_entry))facts$ieepa_ftz_entry<-FALSE
  cases[[length(cases)+1L]] <<- list(name=name,hts10=hts,country=country,entry_at='2026-10-10T12:00:00-04:00',facts=facts,
    expected=list(known_subtotal=subtotal,applied_codes=as.list(sort(codes)),missing_inputs=as.list(sort(missing)),
      source_error=source_error,reporting=reporting))
}
steel <- list(customs_value=100,ieepa_ftz_entry=FALSE,steel_weight_fraction=1,us_steel_origin_fraction=0)
add('ordinary steel exact source heading','7318158085','5700',steel,50,'9903.82.02')
add('country-specific Russian steel heading','7318158085','4621',steel,50,'9903.82.14')
q<-steel;q$us_steel_origin_fraction<-.85
add('US-origin derivative concession boundary','7318158085','5700',q,10,'9903.82.06')
add('Russian derivative with qualifying US steel','7318158085','4621',q,10,'9903.82.15')
q<-steel;q$uk_steel_origin_fraction<-.95
add('UK steel and clarified qualifying production','7318158085','4120',q,25,'9903.82.04')
q$uk_steel_origin_fraction<-.949
add('UK threshold is not rounded','7318158085','4120',q,50,'9903.82.02')
q<-list(customs_value=100,aluminum_weight_fraction=0,steel_weight_fraction=0,copper_weight_fraction=0)
add('metal-free reporting is affirmative zero','8403100000','5700',q,0,'9903.82.01')
q<-list(customs_value=100,steel_weight_fraction=.149)
add('underweight derivative needs no use or origin facts','8403100000','5700',q,0,'9903.82.03')
q<-list(customs_value=100,steel_weight_fraction=.15,us_steel_origin_fraction=0,
  motorcycle_part_for_us_manufacture=FALSE,parts_exclusively_for_us_note16_equipment=FALSE)
add('weight boundary enters ordinary derivative tier','8403100000','5700',q,25,'9903.82.09')
q$motorcycle_part_for_us_manufacture<-TRUE
add('motorcycle use selects source zero heading','8403100000','5700',q,0,'9903.82.13')
q$motorcycle_part_for_us_manufacture<-FALSE;q$parts_exclusively_for_us_note16_equipment<-TRUE;q$column1_duty_amount<-5
add('equipment use selects the floor over the published Free benchmark','8403100000','5700',q,15,'9903.82.25')
q$column1_duty_amount<-15
add('caller amount cannot invent a satisfied floor over a Free expression','8403100000','5700',q,15,'9903.82.25')
q$us_steel_origin_fraction<-.85;q$column1_duty_amount<-5
add('equipment domestic threshold has its own source-backed floor','8403100000','5700',q,10,'9903.82.23')
q<-list(customs_value=100,aluminum_weight_fraction=.1,steel_weight_fraction=.1,
  aluminum_primary_smelted_or_cast_russia=FALSE,us_aluminum_origin_fraction=.85,us_steel_origin_fraction=.85,column1_duty_amount=5)
add('mixed-metal requirements cumulative over native 1.4 percent base','8415908010','5700',q,8.6,'9903.82.07')
q$us_steel_origin_fraction<-.84
add('one nonqualifying metal selects the floor over native 1.4 percent base','8415908010','5700',q,13.6,'9903.82.10')
q$us_steel_origin_fraction<-NULL
add('missing actual origin is a shipment input','8415908010','5700',q,0,missing='us_steel_origin_fraction')
q$us_steel_origin_fraction<-.84
add('non-NTR exact alternative, no floor','8415908010','2390',q,25,'9903.82.12')
add('Russian exact alternative, no floor','8415908010','4621',q,200,'9903.85.68')
q<-list(customs_value=100,aluminum_weight_fraction=1,aluminum_primary_smelted_or_cast_russia=FALSE)
add('primary aluminum source-derived heading','7616995160','5700',q,50,'9903.82.02')
q$aluminum_primary_smelted_or_cast_russia<-TRUE
add('Russian smelt survives non-Russian origin','7616995160','5700',q,200,'9903.85.67')
q<-list(customs_value=100,aluminum_weight_fraction=.01,steel_weight_fraction=.01,
  aluminum_primary_smelted_or_cast_russia=TRUE)
add('Russian derivative exception is full value','8415908010','5700',q,200,'9903.85.68')
q<-list(customs_value=100,steel_weight_fraction=.5,us_steel_origin_fraction=0,
  motorcycle_part_for_us_manufacture=FALSE,column1_duty_amount=5)
add('mobile-equipment partner floor uses the published Free benchmark','8427104090','5880',q,15,'9903.82.22')
add('mobile-equipment nonpartner ordinary tier','8427104090','5700',q,25,'9903.82.09')
q$claims<-list('USMCA');q$usmca_origin_eligible<-TRUE;q$us_produced_parts_value<-70
add('USMCA content capped with two reporting lines','8427104090','2010',q,15,c('9903.82.20','9903.82.21'))
q$us_produced_parts_value<-20
add('USMCA actual non-US content','8427104090','1220',q,20,c('9903.82.20','9903.82.21'))
q$us_produced_parts_value<-0
add('zero exempt content does not invent second line','8427104090','2010',q,25,'9903.82.20')
q$us_produced_parts_value<-101
add('conflicting US parts value requests corrected inputs','8427104090','2010',q,0,
  missing=c('customs_value','us_produced_parts_value'))
q$us_produced_parts_value<-0
q$us_steel_origin_fraction<-.85
add('native Free benchmark resolves the mobile US-metal amount','8427104090','2010',q,10,'9903.82.06')
add('adjacent statistical suffix not broadened','7616995161','5700',list(customs_value=100),0)
add('electronics outside note16 stays outside this fragment','8473301180','5700',list(customs_value=100),0)
q<-steel;q$modeled_share<-0;q$assembly_credit<-9999
add('aggregate inputs cannot change heading','7318158085','5700',q,50,'9903.82.02')
q<-list(customs_value=100,aluminum_weight_fraction=.6,steel_weight_fraction=.6)
add('conflicting weight totals request corrected inputs','8415908010','5700',q,0,
  missing=c('aluminum_weight_fraction','steel_weight_fraction'))
for(case in cases) {
  r <- evaluate_shipment_bundle(bundle,case$hts10,case$country,case$entry_at,case$facts)
  codes <- sort(unique(unlist(lapply(Filter(function(c) c$status=='applied',r$components),`[[`,'reporting_codes'))))
  expected <- case$expected
  if(abs(r$known_subtotal-expected$known_subtotal)>1e-9 || !setequal(codes,unlist(expected$applied_codes)) ||
     !setequal(r$missing_inputs,unlist(expected$missing_inputs))) {
    print(list(case=case$name,got=r[c('known_subtotal','missing_inputs','source_errors')],codes=codes,expected=expected))
    stop('Note 16 decision regression')
  }
  stopifnot(is.null(r$complete_total),r$status=='unresolved_source') # not all-authority coverage
  if(!is.null(expected$source_error)) stopifnot(any(grepl(expected$source_error,r$source_errors,fixed=TRUE)))
  stopifnot(!any(grepl('inconsistent_metal_weight_fractions|inconsistent_us_content_value',r$source_errors)))
  if(!is.null(expected$reporting)) stopifnot(expected$reporting %in% unlist(lapply(r$components,`[[`,'reporting_codes')))
}
# Order and exact duplicates cannot change the result. Compare entire decision
# outputs, including false branches and sources, not just the summed rate.
shuffled <- bundle;shuffled$rules<-c(rev(bundle$rules),bundle$rules[1])
stopifnot(identical(evaluate_shipment_bundle(bundle,'7318158085','5700',cases[[1]]$entry_at,steel),
                   evaluate_shipment_bundle(shuffled,'7318158085','5700',cases[[1]]$entry_at,steel)))
first<-load_s232_note16_source('2026_rev_5')
stopifnot(first$parameters$domestic[[1]]$minimum_fraction==.95,
          x$parameters$domestic[[1]]$minimum_fraction==.85,
          !first$amendments[[1]]$native_heading_present,
          '9903.82.01' %in% vapply(first$headings,`[[`,character(1),'code'))
early_fragment<-compile_s232_note16_fragment(first,products)
early_base<-base;early_base$revision<-first$revision;early_base$valid_from<-early_fragment$supported_from
early_base$valid_until<-early_fragment$supported_until
early_bundle<-compose_shipment_rules(early_base,list(early_fragment))
early_cases<-list(
  list(name='historical 95 percent threshold',facts=list(customs_value=100,ieepa_ftz_entry=FALSE,steel_weight_fraction=1,us_steel_origin_fraction=.9),subtotal=50,code='9903.82.02'),
  list(name='historical qualifying domestic metal',facts=list(customs_value=100,ieepa_ftz_entry=FALSE,steel_weight_fraction=1,us_steel_origin_fraction=.95),subtotal=10,code='9903.82.06'),
  list(name='retroactive zero heading absent from original snapshot',facts=list(customs_value=100,ieepa_ftz_entry=FALSE,steel_weight_fraction=0,aluminum_weight_fraction=0,copper_weight_fraction=0),subtotal=0,code='9903.82.01'))
for(case in early_cases) {
  r<-evaluate_shipment_bundle(early_bundle,'7318158085','5700','2026-04-06T00:01:00-04:00',case$facts)
  stopifnot(r$known_subtotal==case$subtotal,!length(r$missing_inputs),
    case$code %in% unlist(lapply(Filter(function(c)c$status=='applied',r$components),`[[`,'reporting_codes')))
}
stopifnot(is.null(evaluate_shipment_bundle(early_bundle,'7318158085','5700','2026-04-06T00:00:59-04:00',steel)$complete_total))
if('--emit' %in% commandArgs(trailingOnly=TRUE)) jsonlite::write_json(list(bundle=bundle,cases=cases),
  'tests/fixtures/shipment/note16-composition.json',auto_unbox=TRUE,null='null',digits=NA)
cat(length(cases)+length(early_cases),'source-backed note 16 heading/amount/input cases passed; no all-authority attestation\n')
# Note 16(b) preserves these duties when a different Chapter 99 program has a
# lower rate. A registered Section 301 exclusion does not remove Section 232.
claim_source<-list(id='synthetic-301-interaction',status='verified',sha256=paste(rep('0',64),collapse=''),
 url='https://example.invalid/interaction',citation='Synthetic claim identity; not a legal scope fixture')
interaction<-base;interaction$sources<-c(interaction$sources,list(claim_source))
interaction$rules<-list(list(id='synthetic-exclusion',authority='section_301',action_id='synthetic-exclusion',kind='duty',
 verification='verified',scope=list(hts_exact=list('7318158085'),countries=list('5700')),
 when=list(claim='section301:test'),formula=list(value=0),reporting_codes=list('9903.88.69'),source_ids=list(claim_source$id)))
interaction$rules[[1]]$exclusion_claim_id<-'section301:test'
interaction$claim_definitions<-list(list(id='section301:test',label='Synthetic exclusion',rule_ids=list('synthetic-exclusion'),
 candidate_rule_ids=list('synthetic-exclusion'),source_ids=list(claim_source$id)))
interaction<-compose_shipment_rules(interaction,list(fragment));q<-steel;q$claims<-list('section301:test')
r<-evaluate_shipment_bundle(interaction,'7318158085','5700',cases[[1]]$entry_at,q)
stopifnot(r$known_subtotal==50,!any(grepl('claim_not_priced',r$source_errors)))
# A different claim attached to a Section 301 rule is not an exclusion review.
unreviewed<-base;unreviewed$sources<-c(unreviewed$sources,list(claim_source))
unreviewed$rules<-list(interaction$rules[[which(vapply(interaction$rules,function(r) r$id=='synthetic-exclusion',logical(1)))]] )
unreviewed$rules[[1]]$exclusion_claim_id<-NULL
unreviewed$claim_definitions<-list(list(id='section301:test',label='Synthetic exclusion',rule_ids=list('synthetic-exclusion'),
 candidate_rule_ids=list('synthetic-exclusion'),source_ids=list(claim_source$id)))
unreviewed<-compose_shipment_rules(unreviewed,list(fragment))
r<-evaluate_shipment_bundle(unreviewed,'7318158085','5700',cases[[1]]$entry_at,q)
stopifnot(r$known_subtotal==0,any(grepl('claim_not_priced',r$source_errors)))
cat('Note 16 and registered Section 301 exclusion independence passed\n')
