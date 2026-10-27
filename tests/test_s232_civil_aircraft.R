suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/section232_civil_aircraft.R');source('src/compile_shipment_rules.R')
# Real agreement scopes; controlled metal/301 amounts establish interactions,
# not a complete legal oracle for the product or for Section301 origin scope.
products<-c('7304313000','8473301180');countries<-c('4280','4120','5880','5800','4419')
bundles<-list();prepared<-list();cases<-list();sid<-'controlled-aircraft-interaction'
make<-function(rev) {
 f<-compile_s232_civil_aircraft_fragment(rev,products)
 b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
 b$revision<-rev;b$dataset_version<-'civil-aircraft-regression-not-production';b$products<-as.list(products);b$countries<-as.list(countries)
 b$sources<-list(list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/aircraft',citation='Controlled metal and Section301 actions; not product/origin applicability assertions'))
 b$coverage<-list();b$coverage_requirements<-list('base','section_232','section_301');b$fact_definitions<-list();b$claim_definitions<-list()
 b$valid_from<-f$supported_from;b$valid_until<-f$supported_until;b$rules<-list()
 boundary<-f$civil_aircraft_history$modern_from
 for(country in countries)for(modern in c(FALSE,TRUE)) {
  r<-list(id=paste('controlled-metal',country,modern,sep='-'),action_id='controlled-metal',authority='section_232',kind='duty',verification='verified',source_ids=list(sid),
   when=list(value=TRUE),formula=list(value=50),reporting_codes=list(if(modern)'9903.82.02' else if(country=='4120')'9903.81.94' else '9903.81.87'),
   scope=list(hts_exact=as.list(products),countries=list(country)))
  if(modern)r$scope$from<-boundary else r$scope$until<-boundary
  b$rules[[length(b$rules)+1L]]<-r
 }
 b$rules[[length(b$rules)+1L]]<-list(id='controlled-301',action_id='controlled-301',authority='section_301',kind='duty',verification='verified',source_ids=list(sid),reporting_codes=list('9903.88.03'),formula=list(value=20))
 compose_shipment_rules(b,list(f))
}
for(rev in c('2025_rev_15','2025_rev_20','2026_rev_4','2026_rev_5','2026_rev_19'))bundles[[rev]]<-make(rev)
reporter<-c('4280'='9903.02.76','4120'='9903.96.01','5880'='9903.96.02','5800'='9903.02.81')
factkey<-function(country)if(country=='4120')'uk_civil_aircraft_gn6' else 'reciprocal_partner_civil_aircraft_gn6_excluding_unmanned'
add<-function(name,rev,at,country='4280',eligible=TRUE,ftz=FALSE,hts=products[1],subtotal=20,codes=reporter[[country]],missing=character(),source_error=NULL) {
 facts<-structure(list(),names=character());if(!is.null(eligible))facts[[factkey(country)]]<-eligible
 if(!is.null(ftz))facts$ieepa_ftz_entry<-ftz
 if(is.null(prepared[[rev]]))prepared[[rev]]<<-prepare_shipment_bundle(bundles[[rev]])
 r<-evaluate_shipment_prepared(prepared[[rev]],hts,country,at,facts)
 actual<-sort(unique(unlist(lapply(Filter(function(c)c$authority=='section_232'&&c$status=='applied',r$components),`[[`,'reporting_codes'))))
 if(r$known_subtotal!=subtotal||!setequal(actual,codes)||!setequal(r$missing_inputs,missing)) {
  print(list(case=name,result=r[c('known_subtotal','missing_inputs','source_errors')],codes=actual));stop('Aircraft agreement regression')
 }
 stopifnot(is.null(r$complete_total),'controlled-301' %in% r$applied_rules)
 if(!is.null(source_error))stopifnot(any(grepl(source_error,r$source_errors,fixed=TRUE)))
 cases[[length(cases)+1L]]<<-list(name=name,bundle=rev,hts10=hts,country=country,entry_at=at,facts=facts,
  expected=list(known_subtotal=subtotal,codes=as.list(actual),missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors)))
}
add('UK before agreement minute retains metal','2025_rev_15','2025-06-30T00:00:59-04:00',country='4120',subtotal=70,codes='9903.81.94')
add('UK exact agreement minute waives metal','2025_rev_15','2025-06-30T00:01:00-04:00',country='4120')
add('EU before retroactive agreement minute retains metal','2025_rev_20','2025-09-01T00:00:59-04:00',subtotal=70,codes='9903.81.87')
add('EU exact retroactive agreement minute waives metal','2025_rev_20','2025-09-01T00:01:00-04:00')
for(country in names(reporter)) {
 add(paste(country,'Section232 agreement survives IEEPA collection ending'),'2026_rev_4','2026-02-24T00:00:00-05:00',country=country)
 add(paste(country,'before April heading replacement'),'2026_rev_5','2026-04-06T00:00:59-04:00',country=country)
 add(paste(country,'exact April replacement retains exemption'),'2026_rev_5','2026-04-06T00:01:00-04:00',country=country)
 add(paste(country,'later revision retains independent agreement'),'2026_rev_19','2026-09-15T12:00:00-04:00',country=country)
 add(paste(country,'ineligible article remains charged'),'2026_rev_19','2026-09-15T12:00:00-04:00',country=country,eligible=FALSE,ftz=NULL,subtotal=70,codes='9903.82.02')
 add(paste(country,'unknown aircraft eligibility holds metal subtotal'),'2026_rev_19','2026-09-15T12:00:00-04:00',country=country,eligible=NULL,missing=factkey(country),codes=character())
}
add('Swiss reciprocal aircraft concession does not waive metal','2026_rev_19','2026-09-15T12:00:00-04:00',country='4419',eligible=NULL,ftz=NULL,subtotal=70,codes='9903.82.02')
add('Unlisted statistical product does not request aircraft facts','2026_rev_19','2026-09-15T12:00:00-04:00',eligible=NULL,ftz=NULL,hts=products[2],subtotal=70,codes='9903.82.02')
add('Qualifying aircraft requires ordinary versus FTZ history','2026_rev_19','2026-09-15T12:00:00-04:00',ftz=NULL,subtotal=20,codes=character(),missing='ieepa_ftz_entry')
add('FTZ aircraft agreement is explicitly unpriced','2026_rev_19','2026-09-15T12:00:00-04:00',ftz=TRUE,subtotal=20,codes=character(),source_error='civil_aircraft_ftz_admission_and_agreement_history')
if('--emit'%in%commandArgs(TRUE)) {
 path<-tempfile(fileext='.json.gz',tmpdir='tests/fixtures/shipment');out<-gzfile(path,'w')
 writeLines(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=NA),out);close(out)
 stopifnot(file.rename(path,'tests/fixtures/shipment/section232-civil-aircraft.json.gz'))
}
cat(length(cases),'independent civil-aircraft source-window and cross-authority cases passed\n')
