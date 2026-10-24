suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/section232_legacy.R');source('src/compile_shipment_rules.R')
products<-c('7208101500','7202115000','7317005503','7317005590','8708103000','7604101000','7605290000',
 '7210706030','7210706060','7304191020','7304191080','7213914500','7616995160')
make<-function(rev) {
 x<-load_s232_legacy_source(rev);f<-compile_s232_legacy_fragment(x,products)
 b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
 b$rules<-list();b$coverage<-list();b$claim_definitions<-list();b$fact_definitions<-list()
 b$products<-as.list(products);b$countries<-as.list(as.character(read.csv('resources/census_codes.csv')$Code))
 b$valid_from<-f$supported_from;b$valid_until<-f$supported_until;b$coverage_requirements<-list('base','section_232')
 b$revision<-rev;b$dataset_version<-'pre-march-regression-not-release'
 compose_shipment_rules(b,list(f))
}
bundles<-list(january=make('2025_basic'),transition=make('2025_rev_4'))
cases<-list()
add<-function(name,hts,country,facts,subtotal,codes=character(),missing=character(),period='january',entry=NULL,error=NULL) {
 cases[[length(cases)+1L]]<<-list(name=name,bundle=period,hts10=hts,country=country,
 entry_at=entry %||% if(period=='january') '2025-01-15T12:00:00-05:00' else '2025-03-12T00:00:59-04:00',facts=facts,
 expected=list(known_subtotal=subtotal,applied_codes=as.list(sort(codes)),missing_inputs=as.list(sort(missing)),source_error=error))
}
v<-list(customs_value=100)
add('ordinary primary steel','7208101500','5700',v,25,'9903.80.01')
add('ferroalloy is outside enumerated steel scope','7202115000','5700',v,0)
add('Canada steel country exemption','7208101500','1220',v,0)
add('irrelevant individual grant does not block country relief','7208101500','1220',c(v,list(claims=list('section232:individual:steel'))),0)
add('Mexico foreign melt uses special heading','7208101500','2010',c(v,list(steel_melted_poured_us_mexico_canada=FALSE)),25,'9903.81.85')
add('Mexico North American melt exempt','7208101500','2010',c(v,list(steel_melted_poured_us_mexico_canada=TRUE)),0)
add('Mexico unknown melt not zero','7208101500','2010',v,0,missing='steel_melted_poured_us_mexico_canada')
q<-c(v,list(steel_melted_poured_us_mexico_canada=FALSE,claims=list('USMCA')))
add('USMCA does not exempt foreign melt','7208101500','2010',q,25,'9903.81.85')
q<-c(v,list(s232_steel_quota_allocated=TRUE))
add('Argentina allocated absolute quota','7208101500','3570',q,0,'9903.80.07')
q$s232_steel_quota_allocated<-FALSE
add('absolute quota exhausted has no tariff fallback','7208101500','3570',q,0,missing='s232_steel_quota_allocated')
q<-c(v,list(steel_melted_poured_ukraine=FALSE,steel_melted_poured_uk=FALSE,steel_melted_poured_eu=TRUE,s232_steel_quota_allocated=TRUE))
add('EU allocated TRQ','7208101500','4759',q,0,'9903.80.67')
q$s232_steel_quota_allocated<-FALSE
add('EU exhausted TRQ is ordinary duty','7208101500','4759',q,25,'9903.80.01')
q$steel_melted_poured_eu<-FALSE;q$s232_steel_quota_allocated<-NULL
add('EU nonregional melt no quota input needed','7208101500','4759',q,25,'9903.80.01')
q$steel_melted_poured_uk<-TRUE;q$s232_steel_quota_allocated<-TRUE
add('EU UK melt uses separate quota heading','7208101500','4759',q,0,'9903.81.81')
q$steel_melted_poured_ukraine<-TRUE;q$s232_steel_quota_allocated<-NULL
add('EU Ukraine melt relief','7208101500','4759',q,0,'9903.81.82')
add('Ukraine certificate','7208101500','4623',c(v,list(ukraine_steel_certificate_of_origin=TRUE)),0)
add('Ukraine without certificate charged','7208101500','4623',c(v,list(ukraine_steel_certificate_of_origin=FALSE)),25,'9903.81.83')
q<-c(v,list(steel_melted_poured_japan=TRUE,s232_steel_quota_allocated=TRUE))
add('Japan source category','7208101500','5880',q,0,'9903.81.27')
q<-c(v,list(steel_melted_poured_uk=TRUE,uk_steel_producer_trq_access=FALSE))
add('UK denied producer quota access','7208101500','4120',q,25,'9903.80.01')
q<-c(v,list(claims=list('section232:gae:steel')))
add('GAE quota reporting','7210706030','3570',q,0,'9903.80.60')
add('GAE EU no metal heading required','7210706030','4759',q,0)
add('GAE Japan reporting','7210706030','5880',q,0,'9903.81.80')
q<-c(v,list(contains_steel=TRUE,s232_scope_n16_a_B=TRUE))
add('original derivative exact suffix','7317005503','5700',q,25,'9903.80.03')
add('adjacent suffix outside original derivatives','7317005590','5700',q,0)
a<-c(v,list(aluminum_primary_smelted_or_cast_russia=FALSE))
add('ordinary aluminum ten percent','7604101000','5700',a,10,'9903.85.01')
add('Canada retired aluminum heading inactive','7604101000','1220',a,0)
add('Mexico bad smelt aluminum','7604101000','2010',c(a,list(aluminum_smelt_cast_china_russia_belarus_iran=TRUE)),10,'9903.85.71')
r<-c(v,list(aluminum_primary_smelted_or_cast_russia=TRUE,privileged_ftz_before_20230410=FALSE))
add('Russian material overrides Mexico ten percent','7604101000','2010',r,200,'9903.85.67')
q<-c(a,list(aluminum_certificate_of_analysis=TRUE,aluminum_primary_china_russia_belarus=FALSE,s232_aluminum_quota_allocated=TRUE))
add('UK aluminum TRQ','7604101000','4120',q,0,'9903.85.53')
q$aluminum_primary_china_russia_belarus<-TRUE;q$s232_aluminum_quota_allocated<-NULL
add('UK disallowed smelt no quota benefit','7604101000','4120',q,10,'9903.85.01')
q<-c(a,list(claims=list('section232:gae:aluminum')))
add('aluminum GAE EU heading','7605290000','4759',q,0,'9903.85.25')
q$aluminum_primary_smelted_or_cast_russia<-TRUE;q$privileged_ftz_before_20230410<-FALSE
add('aluminum GAE cannot remove Russian action','7605290000','4759',q,200,'9903.85.67')
q<-c(v,list(claims=list('section232:individual:steel')))
add('unverified individual grant cannot price claim','7208101500','5700',q,0,error='individual_commerce_grant_requires_verified')
add('same revision before March amendment uses old heading','7208101500','5700',v,25,'9903.80.01',period='transition')
q<-c(v,list(privileged_ftz_before_20250312=FALSE))
add('same revision at March amendment uses new heading','7208101500','5700',q,25,'9903.81.87',period='transition',entry='2025-03-12T00:01:00-04:00')
for(c in cases) {
 r<-evaluate_shipment_bundle(bundles[[c$bundle]],c$hts10,c$country,c$entry_at,c$facts)
 codes<-sort(unique(unlist(lapply(Filter(function(x)x$status=='applied',r$components),`[[`,'reporting_codes'))))
 if(abs(r$known_subtotal-c$expected$known_subtotal)>1e-9 || !setequal(codes,unlist(c$expected$applied_codes)) ||
    !setequal(r$missing_inputs,unlist(c$expected$missing_inputs)) || (!is.null(c$expected$source_error)&&!any(grepl(c$expected$source_error,r$source_errors)))) {
  print(list(case=c$name,got=r[c('known_subtotal','missing_inputs','source_errors')],codes=codes,expected=c$expected));stop('Pre-March decision regression')
 }
 stopifnot(is.null(r$complete_total),r$status=='unresolved_source')
}
if('--emit' %in% commandArgs(trailingOnly=TRUE)) jsonlite::write_json(list(bundles=bundles,cases=cases),
 'tests/fixtures/shipment/pre-march-metals.json',auto_unbox=TRUE,null='null',digits=NA)
cat(length(cases),'pre-March source-backed decisions passed; full coverage not attested\n')
# Cross-authority effects must use the actual emergency result after claims.
f<-compile_s232_legacy_fragment(load_s232_legacy_source('2025_rev_4'),products)
b<-bundles$transition;b$rules<-list();b$fact_definitions<-list();b$claim_definitions<-list();b$coverage<-list()
rule<-function(id,code,authority,formula,when=list(value=TRUE)) list(id=id,action_id=id,authority=authority,kind='duty',verification='verified',
 scope=list(hts_exact=list('7208101500'),countries=list('2010')),when=when,formula=formula,reporting_codes=list(code),source_ids=list(b$sources[[1]]$id))
b$rules<-list(rule('emergency','9903.01.01','ieepa_fentanyl',list(value=25),list(op='not',args=list(list(claim='USMCA')))))
b$claim_definitions<-list(list(id='USMCA',label='USMCA',rule_ids=list('emergency'),source_ids=list(b$sources[[1]]$id)))
b<-compose_shipment_rules(b,list(f));q<-list(customs_value=100,steel_melted_poured_us_mexico_canada=FALSE)
r<-evaluate_shipment_bundle(b,'7208101500','2010','2025-03-10T12:00:00-04:00',q)
stopifnot(r$known_subtotal==25,any(startsWith(unlist(r$suppressed_rules),'s232_pre_march')))
q$claims<-list('USMCA');r<-evaluate_shipment_bundle(b,'7208101500','2010','2025-03-10T12:00:00-04:00',q)
stopifnot(r$known_subtotal==25,any(vapply(r$components,function(c) '9903.81.85' %in% unlist(c$reporting_codes)&&c$status=='applied',logical(1))))
# A metal GAE leaves ordinary base, China emergency and Section 301 duties intact.
f<-compile_s232_legacy_fragment(load_s232_legacy_source('2025_basic'),products)
b<-bundles$january;b$rules<-list();b$fact_definitions<-list();b$claim_definitions<-list();b$coverage<-list()
for(authority in c('base','section_301','ieepa_fentanyl')) {
 z<-rule(authority,'9903.88.01',authority,list(value=5));z$scope<-list(hts_exact=list('7210706030'),countries=list('5700'));b$rules<-c(b$rules,list(z))
}
b<-compose_shipment_rules(b,list(f));q<-list(customs_value=100,claims=list('section232:gae:steel'))
r<-evaluate_shipment_bundle(b,'7210706030','5700','2025-01-15T12:00:00-05:00',q)
stopifnot(r$known_subtotal==15,!any(grepl('claim_not_priced',r$source_errors)))
cat('Emergency positive-duty priority, USMCA revival and GAE independence passed\n')
