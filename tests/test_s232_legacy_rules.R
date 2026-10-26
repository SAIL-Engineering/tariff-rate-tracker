suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/section232_legacy.R');source('src/compile_shipment_rules.R')
products<-c('7318158085','7308200035','7308200036','7304110010','7208101500','7202115000',
  '8431310040','7604101000','7616995160','2203000030','7317005503','7317005590','7302909000')
make_bundle<-function(rev) {
 x<-load_s232_legacy_source(rev);f<-compile_s232_legacy_fragment(x,products)
 b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
 b$rules<-list();b$coverage<-list();b$claim_definitions<-list();b$fact_definitions<-list()
 b$products<-as.list(products);b$countries<-as.list(as.character(read.csv('resources/census_codes.csv')$Code))
 b$valid_from<-f$supported_from;b$valid_until<-f$supported_until
 b$coverage_requirements<-list('base','section_232');b$revision<-rev;b$dataset_version<-'legacy-metal-regression-not-release'
 compose_shipment_rules(b,list(f))
}
bundles<-list(late=make_bundle('2026_rev_4'),early=make_bundle('2025_rev_4'),june=make_bundle('2025_rev_14'))
cases<-list()
add<-function(name,hts,country,facts,subtotal,codes=character(),missing=character(),period='late',entry=NULL) {
 cases[[length(cases)+1L]]<<-list(name=name,bundle=period,hts10=hts,country=country,
 entry_at=entry %||% if(period=='late') '2026-03-01T12:00:00-05:00' else '2025-03-12T00:01:00-04:00',facts=facts,
 expected=list(known_subtotal=subtotal,applied_codes=as.list(sort(codes)),missing_inputs=as.list(sort(missing))))
}
steel<-list(customs_value=100,steel_content_value=20,contains_steel=TRUE,
 steel_processed_from_us_metal=FALSE,privileged_ftz_before_20250604=FALSE)
add('primary heading expressly yields to derivative heading','7302909000','5700',steel,10,'9903.81.90')
add('China chapter 73 uses declared steel content','7318158085','5700',steel,10,'9903.81.90')
add('UK derivative has its own heading','7318158085','4120',steel,5,'9903.81.97')
add('outside-chapter machine part has content heading','8431310040','5700',steel,10,'9903.81.91')
add('UK machine part note overrides abbreviated rate','8431310040','4120',steel,5,'9903.81.98')
q<-steel;q$steel_processed_from_us_metal<-TRUE;q$privileged_ftz_before_20250604<-NULL
add('US steel relief does not ask FTZ or content value','7318158085','5700',q,0,'9903.81.92')
q<-steel;q$contains_steel<-FALSE
add('candidate containing no steel owes no steel duty','8431310040','5700',q,0)
q<-steel;q$privileged_ftz_before_20250604<-TRUE
add('privileged FTZ selects distinct derivative heading','7318158085','5700',q,10,'9903.81.93')
add('UK privileged FTZ distinct heading','7318158085','4120',q,5,'9903.81.99')
q<-steel;q$claims<-list('USMCA')
add('USMCA alone does not erase metal liability','7318158085','1220',q,10,'9903.81.90')
q<-steel;q$steel_content_value<-NULL
add('missing content cannot become zero','7318158085','5700',q,0,missing='steel_content_value')
q<-steel;q$steel_content_value<-101
add('content above article value requests correction','7318158085','5700',q,0,missing=c('steel_content_value','customs_value'))
add('excluded primary steel chapter product stays out','7202115000','5700',list(customs_value=100),0)
q<-list(customs_value=100,steel_content_value=40,privileged_ftz_before_20250604=FALSE)
add('chapter 73 primary metal uses content after June','7304110010','5700',q,20,'9903.81.87')
add('chapter 72 primary metal uses full value','7208101500','5700',q,50,'9903.81.87')
alum<-list(customs_value=100,aluminum_content_value=10,contains_aluminum=TRUE,
 aluminum_processed_from_us_metal=FALSE,aluminum_primary_smelted_or_cast_russia=FALSE)
add('beer metal component is separately valued, no total oracle','2203000030','1220',alum,5,'9903.85.08')
add('primary aluminum content valued after June','7604101000','5700',alum,5,'9903.85.02')
q<-alum;q$aluminum_primary_smelted_or_cast_russia<-TRUE;q$privileged_ftz_before_20230410<-FALSE
add('Russian smelt in another origin is full value','2203000030','1220',q,200,'9903.85.68')
q$privileged_ftz_before_20230410<-TRUE
add('Russian smelt privileged FTZ reporting','2203000030','1220',q,200,'9903.85.70')
q<-alum;q$privileged_ftz_before_20230410<-FALSE
add('Russian origin independently triggers treatment','7604101000','4621',q,200,'9903.85.67')
q<-alum;q$aluminum_processed_from_us_metal<-TRUE
add('US aluminum derivative relief','2203000030','1220',q,0,'9903.85.09')
q<-c(steel,alum[setdiff(names(alum),names(steel))])
add('mixed-metal structure keeps both actions','7308200035','5700',q,15,c('9903.81.90','9903.85.08'))
add('adjacent suffix does not acquire aluminum scope','7308200036','5700',q,10,'9903.81.90')
q<-steel;q$modeled_share<-0;q$assembly_credit<-100000
add('modeled inputs cannot affect shipment','7318158085','5700',q,10,'9903.81.90')
q<-steel;q$privileged_ftz_before_20250312<-FALSE
add('before June chapter 73 derivative full value','7318158085','5700',q,25,'9903.81.90',period='early')
add('new heading is not effective one second early','7318158085','5700',q,0,period='early',entry='2025-03-12T00:00:59-04:00')
add('before June outside-chapter derivative content','8431310040','5700',q,5,'9903.81.91',period='early')
add('June amendment one second before keeps prior full-value treatment','7318158085','5700',q,25,'9903.81.90',
 period='june',entry='2025-06-04T00:00:59-04:00')
add('June amendment at the minute changes rate and value basis','7318158085','5700',q,10,'9903.81.90',
 period='june',entry='2025-06-04T00:01:00-04:00')
add('UK heading before the June amendment stays ordinary','7318158085','4120',q,25,'9903.81.90',
 period='june',entry='2025-06-04T00:00:59-04:00')
add('UK heading at the June amendment changes to UK heading','7318158085','4120',q,5,'9903.81.97',
 period='june',entry='2025-06-04T00:01:00-04:00')
for(c in cases) {
 r<-evaluate_shipment_bundle(bundles[[c$bundle]],c$hts10,c$country,c$entry_at,c$facts)
 codes<-sort(unique(unlist(lapply(Filter(function(x)x$status=='applied',r$components),`[[`,'reporting_codes'))))
 if(abs(r$known_subtotal-c$expected$known_subtotal)>1e-9 || !setequal(codes,unlist(c$expected$applied_codes)) ||
    !setequal(r$missing_inputs,unlist(c$expected$missing_inputs))) {
   print(list(case=c$name,got=r[c('known_subtotal','missing_inputs','source_errors')],codes=codes,expected=c$expected))
   stop('Legacy metal legal decision regression')
 }
 stopifnot(is.null(r$complete_total),r$status=='unresolved_source')
}
cat(length(cases),'source-backed historical metal decisions passed; complete coverage is not attested\n')
# Composition fixtures exercise action dependencies; the added charge itself is
# synthetic and is not an oracle for a real automobile or emergency rate.
base<-bundles$late
base$sources<-c(base$sources,list(list(id='synthetic-composition',status='verified',sha256=paste(rep('0',64),collapse=''),
 url='https://example.invalid/composition-test',citation='Synthetic dependency fixture; not a tariff rate source')))
fixture_rule<-function(id,code,authority,amount,when=list(value=TRUE)) list(id=id,action_id=id,authority=authority,
 kind='duty',verification='verified',scope=list(hts_exact=list('7318158085'),countries=list('1220')),
 when=when,formula=list(value=amount),reporting_codes=list(code),source_ids=list('synthetic-composition'))
x<-load_s232_legacy_source('2026_rev_4');fragment<-compile_s232_legacy_fragment(x,products)
auto<-fixture_rule('synthetic-auto','9903.94.05','section_232',25,list(op='not',args=list(list(claim='USMCA'))))
base$rules<-list(auto);base$fact_definitions<-list();base$claim_definitions<-list(list(id='USMCA',label='USMCA',
 rule_ids=list(auto$id),source_ids=list('synthetic-composition')))
b<-compose_shipment_rules(base,list(fragment));q<-steel
r<-evaluate_shipment_bundle(b,'7318158085','1220','2026-03-01T12:00:00-05:00',q)
stopifnot(r$known_subtotal==25)
q$claims<-list('USMCA');r<-evaluate_shipment_bundle(b,'7318158085','1220','2026-03-01T12:00:00-05:00',q)
stopifnot(r$known_subtotal==10) # claim removes the auto branch, metal liability is reevaluated
# Proclamation 10984 clause 9 changes CBP's earlier positive-payable test.
# An applicable vehicle action remains subject to Section 232 at zero payable.
base$rules[[1]]$formula<-list(value=0);b<-compose_shipment_rules(base,list(fragment))
stopifnot(evaluate_shipment_bundle(b,'7318158085','1220','2026-03-01T12:00:00-05:00',steel)$known_subtotal==0)
# A named Section 301 exclusion changes that authority alone.
c301<-fixture_rule('synthetic-301-exclusion','9903.88.69','section_301',0,list(claim='section301:test'))
c301$exclusion_claim_id<-'section301:test'
base$rules<-list(c301);base$claim_definitions<-list(list(id='section301:test',label='Synthetic Section 301 exclusion',
 rule_ids=list(c301$id),candidate_rule_ids=list(c301$id),source_ids=list('synthetic-composition')))
b<-compose_shipment_rules(base,list(fragment));q<-steel;q$claims<-list('section301:test')
r<-evaluate_shipment_bundle(b,'7318158085','1220','2026-03-01T12:00:00-05:00',q)
stopifnot(r$known_subtotal==10,!any(grepl('claim_not_priced',r$source_errors)))
base$rules[[1]]$exclusion_claim_id<-NULL
unreviewed<-compose_shipment_rules(base,list(fragment))
r<-evaluate_shipment_bundle(unreviewed,'7318158085','1220','2026-03-01T12:00:00-05:00',q)
stopifnot(r$known_subtotal==0,any(grepl('claim_not_priced',r$source_errors)))
cat('Auto precedence, zero-duty floor, USMCA reevaluation and Section 301 exclusion independence passed\n')
# The actual emergency amount is deliberately synthetic; these tests isolate
# the verified change of ordering and claim reevaluation, not a complete stack.
early_fragment<-compile_s232_legacy_fragment(load_s232_legacy_source('2025_rev_4'),products)
base<-bundles$early;base$sources<-c(base$sources,list(list(id='synthetic-composition',status='verified',sha256=paste(rep('0',64),collapse=''),
 url='https://example.invalid/composition-test',citation='Synthetic action relation test')))
emergency<-fixture_rule('synthetic-canada','9903.01.10','ieepa_fentanyl',25,list(op='not',args=list(list(claim='USMCA'))))
base$rules<-list(emergency);base$claim_definitions<-list(list(id='USMCA',label='USMCA',rule_ids=list(emergency$id),source_ids=list('synthetic-composition')))
b<-compose_shipment_rules(base,list(early_fragment));q<-steel;q$privileged_ftz_before_20250312<-FALSE
r<-evaluate_shipment_bundle(b,'7318158085','1220','2025-03-12T12:00:00-04:00',q)
stopifnot(r$known_subtotal==25,!any(grepl('cyclic',r$source_errors)))
q$claims<-list('USMCA');r<-evaluate_shipment_bundle(b,'7318158085','1220','2025-03-12T12:00:00-04:00',q)
stopifnot(r$known_subtotal==25,any(vapply(r$components,function(x) x$status=='applied'&&'9903.81.90'%in%unlist(x$reporting_codes),logical(1))))
june_fragment<-compile_s232_legacy_fragment(load_s232_legacy_source('2025_rev_14'),products)
base$valid_from<-june_fragment$supported_from;base$valid_until<-june_fragment$supported_until
b<-compose_shipment_rules(base,list(june_fragment));q$claims<-NULL
for (at in c('2025-06-04T00:00:59-04:00','2025-06-04T00:01:00-04:00')) {
 r<-evaluate_shipment_bundle(b,'7318158085','1220',at,q)
 stopifnot(r$known_subtotal==if(grepl('00:00:59',at))25 else 10,!any(grepl('cyclic',r$source_errors)))
}
cat('Canada emergency priority, USMCA revival and exact June precedence transition passed\n')
q$steel_content_value<-0
r<-evaluate_shipment_bundle(b,'7318158085','1220','2025-06-04T00:01:00-04:00',q)
stopifnot(r$known_subtotal==25)
cat('Zero metal duty cannot suppress an otherwise owed emergency charge\n')
# CBP 90 FR 21487 footnote 1 expressly includes the Russian-aluminum action
# in EO 14289. The action remains covered when the priority changes in June.
base$rules[[1]]$scope$hts_exact<-list('7604101000')
b<-compose_shipment_rules(base,list(june_fragment))
q<-alum;q$aluminum_primary_smelted_or_cast_russia<-TRUE;q$privileged_ftz_before_20230410<-FALSE
for(at in c('2025-06-04T00:00:59-04:00','2025-06-04T00:01:00-04:00')) {
 r<-evaluate_shipment_bundle(b,'7604101000','1220',at,q)
 stopifnot(r$known_subtotal==if(grepl('00:00:59',at))25 else 200)
}
cat('Russian-aluminum action follows the source-confirmed precedence transition\n')
# All source-defined ordinary CA/MX emergency treatments participate; the
# energy/potash rates are not silently omitted by an abbreviated heading list.
# Synthetic amounts isolate ordering, and do not attest real product scope.
base$rules<-list(emergency);base$rules[[1]]$scope$countries<-list('1220','2010')
base$valid_from<-june_fragment$supported_from;base$valid_until<-june_fragment$supported_until
q<-steel;q$privileged_ftz_before_20250312<-FALSE
record_interaction<-function(name,b,facts,subtotal,codes,at,country) {
 r<-evaluate_shipment_bundle(b,'7318158085',country,at,facts)
 got<-unique(unlist(lapply(Filter(function(x)x$status=='applied',r$components),`[[`,'reporting_codes')))
 stopifnot(r$known_subtotal==subtotal,setequal(got,codes),!length(r$missing_inputs),
           !any(grepl('cyclic',r$source_errors)),is.null(r$complete_total))
 key<-paste0('interaction_',length(bundles)+1L);bundles[[key]]<<-b
 add(name,'7318158085',country,facts,subtotal,codes,period=key,entry=at)
}
for(code in c('9903.01.01','9903.01.05','9903.01.10','9903.01.13','9903.01.15')) {
 base$rules[[1]]$reporting_codes<-list(code)
 b<-compose_shipment_rules(base,list(june_fragment))
 country<-if(code %in% c('9903.01.01','9903.01.05')) '2010' else '1220'
 for(at in c('2025-06-04T00:00:59-04:00','2025-06-04T00:01:00-04:00')) {
  before<-grepl('00:00:59',at)
  record_interaction(paste('ordinary emergency priority',code,at),b,q,if(before)25 else 10,
    if(before)code else '9903.81.90',at,country)
 }
 zero<-q;zero$steel_content_value<-0
 record_interaction(paste('zero metal does not suppress',code),b,zero,25,c(code,'9903.81.90'),
   '2025-06-04T00:01:00-04:00',country)
}
# A different authority and a later conditional anti-evasion action must not
# inherit ordinary CA/MX exemptions. This is a relation test, not a rate oracle.
august_fragment<-compile_s232_legacy_fragment(load_s232_legacy_source('2025_rev_18'),products)
base$valid_from<-august_fragment$supported_from;base$valid_until<-august_fragment$supported_until
for(code in c('9903.01.16','9903.01.24','9903.88.01')) {
 base$rules[[1]]$reporting_codes<-list(code)
 country<-if(code=='9903.01.16') '1220' else '5700'
 base$rules[[1]]$authority<-if(code=='9903.88.01') 'section_301' else 'ieepa_fentanyl'
 base$rules[[1]]$scope$countries<-list(country)
 b<-compose_shipment_rules(base,list(august_fragment))
 record_interaction(paste('independent action remains cumulative',code),b,q,35,c(code,'9903.81.90'),
   '2025-08-08T12:00:00-04:00',country)
}
cat('All ordinary CA/MX headings follow exact June ordering; other actions remain independent\n')

if('--emit' %in% commandArgs(trailingOnly=TRUE)) jsonlite::write_json(list(bundles=bundles,cases=cases),
 'tests/fixtures/shipment/legacy-metals.json',auto_unbox=TRUE,null='null',digits=NA)
cat(length(cases),'total historical metal R/TypeScript fixtures passed\n')
