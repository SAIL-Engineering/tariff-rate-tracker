suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/ieepa_reciprocal_revision.R');source('src/compile_shipment_rules.R')
products<-c('0106199120','7318158085','8528520000','7304313000','7411101030')
sid<-'synthetic-reciprocal-interactions'
synthetic<-list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/reciprocal-fixture',
  citation='Synthetic complete Section 232 inventory for dependency regression only')
fragments<-list()
make<-function(rev,metal=NULL,coverage=TRUE,extra=list(),chapter98_metal_fixed=FALSE) {
  if(is.null(fragments[[rev]])) fragments[[rev]]<<-compile_reciprocal_initial_fragment(load_reciprocal_scope(rev),products)
  f<-fragments[[rev]]
  b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
  b$revision<-rev;b$dataset_version<-'reciprocal-regression-not-production';b$products<-as.list(products)
  b$countries<-as.list(c('1220','2010','5700','5820','5660','6021','4279','4120','4621','4622','2390','5790'))
  b$rules<-if(is.null(metal)) list() else if(!is.null(metal$id)) list(metal) else metal
  b$fact_definitions<-list();b$claim_definitions<-list();b$sources<-c(b$sources,list(synthetic))
  # This fixture assumes an independently resolved metal amount after the
  # Chapter 98 claim. It tests reciprocal intersections, not metal claim law.
  if(chapter98_metal_fixed)b$claim_definitions<-list(list(id='CHAPTER_98',label='Chapter 98',source_ids=list(sid),
    rule_ids=as.list(vapply(b$rules,`[[`,character(1),'id'))))
  b$coverage_requirements<-list('base','section_232','ieepa_reciprocal');b$coverage<-list()
  b$valid_from<-f$supported_from;b$valid_until<-f$supported_until
  b<-compose_shipment_rules(b,c(list(f),extra))
  metal_ids<-vapply(Filter(function(r)r$authority=='section_232',b$rules),`[[`,character(1),'id')
  if(coverage)b$coverage<-list(list(authority='section_232',status='verified',source_ids=list(sid),
    determination=if(!length(metal_ids)) 'no_applicable_rules' else 'rules',rule_ids=as.list(metal_ids)))
  b
}
mk<-function(code,amount=0,product=products[2])list(id='synthetic-232',action_id='synthetic-232',authority='section_232',kind='duty',verification='verified',
  source_ids=list(sid),scope=list(hts_exact=as.list(product)),reporting_codes=list(code),when=list(value=TRUE),formula=list(value=amount))
bundles<-list(initial=make('2025_rev_7'),country=make('2025_rev_8'),suspension=make('2025_rev_9'),may=make('2025_rev_12'),
  late=make('2025_rev_13'),boundary=make('2025_rev_14'),zero_metal=make('2025_rev_7',mk('9903.81.92')),charged_metal=make('2025_rev_7',mk('9903.81.91',5)),
  nonauto=make('2025_rev_7',mk('9903.94.06')),auto=make('2025_rev_7',mk('9903.94.01',25)),missing=make('2025_rev_7',coverage=FALSE),
  russian_metal=make('2025_rev_7',mk('9903.85.68',200)),
  june_metal=make('2025_rev_14',mk('9903.81.91',10)),june_uk=make('2025_rev_14',mk('9903.81.98',5)),
  june_russian=make('2025_rev_14',mk('9903.85.68',200)),june_zero=make('2025_rev_14',mk('9903.81.92')),end=make('2025_rev_15'))
bundles$june_repairs<-make('2025_rev_14',mk('9903.81.91',10),chapter98_metal_fixed=TRUE)
aluminum<-mk('9903.85.08',5);aluminum$id<-aluminum$action_id<-'synthetic-aluminum'
bundles$june_mixed<-make('2025_rev_14',list(mk('9903.81.91',10),aluminum))
bundles$july<-make('2025_rev_16')
bundles$july_aircraft<-make('2025_rev_16',mk('9903.81.94',5,products[4]))
bundles$uk_aircraft_boundary<-make('2025_rev_15',mk('9903.81.94',5,products[4]))
bundles$july_unlisted<-make('2025_rev_16',mk('9903.81.94',5))
bundles$august_boundary<-make('2025_rev_17')
bundles$august_new_revision<-make('2025_rev_18')
copper<-mk('9903.78.01',15,products[5]);copper$scope$from<-'2025-08-01T00:01:00-04:00'
bundles$august_copper<-make('2025_rev_17',copper)
bundles$august_copper_repairs<-make('2025_rev_17',copper,chapter98_metal_fixed=TRUE)
steel<-mk('9903.81.91',10,products[5]);steel$id<-steel$action_id<-'synthetic-steel'
bundles$august_mixed<-make('2025_rev_17',list(copper,steel))
q<-list(customs_value=100,ieepa_ftz_entry=FALSE,ieepa_personal_accompanied_baggage=FALSE,
  ieepa_qualifying_humanitarian_donation=FALSE,ieepa_informational_material=FALSE,ieepa_de_minimis_claimed=FALSE)
cases<-list()
add<-function(name,bundle='initial',facts=q,country='6021',hts10=products[1],at=NULL,subtotal=10,codes=NULL,missing=NULL,error=NULL) {
  if(is.null(at))at<-switch(bundle,country='2025-04-09T12:00:00-04:00',suspension='2025-04-10T12:00:00-04:00',may='2025-05-14T12:00:00-04:00',late='2025-05-29T12:00:00-04:00',boundary='2025-06-04T00:00:59-04:00','2025-04-06T12:00:00-04:00')
  r<-evaluate_shipment_bundle(bundles[[bundle]],hts10,country,at,facts)
  actual<-sort(unique(unlist(lapply(Filter(function(x)x$authority=='ieepa_reciprocal'&&x$status=='applied',r$components),`[[`,'reporting_codes'))))
  if(abs(r$known_subtotal-subtotal)>1e-8||(!is.null(codes)&&!setequal(codes,actual))||(!is.null(missing)&&!setequal(missing,r$missing_inputs))||(!is.null(error)&&!any(grepl(error,r$source_errors,fixed=TRUE)))) {
    print(list(case=name,codes=actual,result=r[c('status','known_subtotal','missing_inputs','source_errors')]));stop('Reciprocal regression')
  }
  stopifnot(is.null(r$complete_total))
  cases[[length(cases)+1L]]<<-list(name=name,bundle=bundle,hts10=hts10,country=country,entry_at=at,facts=facts,
    expected=list(known_subtotal=subtotal,codes=as.list(actual),missing_inputs=as.list(r$missing_inputs),source_errors=as.list(r$source_errors)))
}
add('ordinary Annex-II false-zero correction',codes='9903.01.25',missing=character())
add('before initial minute',at='2025-04-05T00:00:59-04:00',subtotal=0,codes=character())
add('initial exact minute',at='2025-04-05T00:01:00-04:00',codes='9903.01.25')
add('retroactive electronics exception',hts10=products[3],facts=list(ieepa_ftz_entry=FALSE),subtotal=0,codes='9903.01.32',missing=character())
for(c in c('1220','2010','4621','4622','2390','5790'))add(paste('country exception',c),country=c,facts=list(ieepa_ftz_entry=FALSE),subtotal=0,missing=character())
add('EU original April 9 rate',bundle='country',country='4279',subtotal=20,codes='9903.01.50')
add('EU before country-rate minute',bundle='country',country='4279',at='2025-04-09T00:00:59-04:00',codes='9903.01.25')
add('China April 9 replacement',bundle='country',country='5700',subtotal=84,codes='9903.01.63')
for(c in c('5700','5820','5660'))add(paste('China group April 10',c),bundle='suspension',country=c,subtotal=125,codes='9903.01.63')
add('China immediately before April 10 replacement',bundle='suspension',country='5700',at='2025-04-10T00:00:59-04:00',subtotal=84)
add('EU suspended rate remains 10',bundle='suspension',country='4279',codes='9903.01.25')
add('May China retains 125 before minute',bundle='may',country='5700',at='2025-05-14T00:00:59-04:00',subtotal=125)
add('May China suspension exact minute',bundle='may',country='5700',at='2025-05-14T00:01:00-04:00',codes='9903.01.25')
add('zero payable named metal remains excepted',bundle='zero_metal',hts10=products[2],subtotal=0,codes='9903.01.33')
add('metal pre June whole-article relief',bundle='charged_metal',hts10=products[2],subtotal=5,codes='9903.01.33')
add('auto subject to duty remains excepted',bundle='auto',hts10=products[2],subtotal=25,codes='9903.01.33')
add('zero non-auto decision is not an exemption',bundle='nonauto',hts10=products[2],codes='9903.01.25')
add('Russian aluminum decision is covered by original proclamation',bundle='russian_metal',hts10=products[2],subtotal=200,codes='9903.01.33')
add('missing 232 inventory never adds presumed reciprocal duty',bundle='missing',subtotal=0,error='coverage_dependency_unverified:section_232')
f<-q;f$claims<-list('RECIPROCAL_US_CONTENT')
add('content claim needs value',facts=f,subtotal=0,missing='reciprocal_us_content_value')
for(u in c(0,19.99,20,40,100)) {
  f$reciprocal_us_content_value<-u
  add(paste('U.S. content threshold',u),facts=f,subtotal=if(u<20)10 else .1*(100-u),
      codes=if(u<20)'9903.01.25' else c('9903.01.25','9903.01.34'))
}
f$customs_value<-1003;f$reciprocal_us_content_value<-200.6
add('exact decimal 20 percent qualifying content',facts=f,subtotal=80.24,codes=c('9903.01.25','9903.01.34'))
f$customs_value<-100
f$reciprocal_us_content_value<-101;add('invalid U.S. value is not clamped',facts=f,subtotal=0,missing=c('reciprocal_us_content_value','customs_value'))
f<-q;f$claims<-list('CHAPTER_98');f$chapter98_properly_claimed_and_cbp_agreed<-TRUE;f$chapter98_provision<-'98010010';f$reciprocal_chapter98_nonpreference<-TRUE
add('proper Chapter 98 exemption',facts=f,subtotal=0,codes=character())
f$reciprocal_chapter98_nonpreference<-FALSE;f$chapter98_provision<-'98206135'
add('Chapter 98 preference does not waive reciprocal duty',facts=f,subtotal=10,codes='9903.01.25')
f$chapter98_provision<-'98020040';f$chapter98_repairs_alterations_processing_value<-30
add('Chapter 98 repairs value',facts=f,subtotal=3,codes='9903.01.25')
f$claims<-c(f$claims,'RECIPROCAL_US_CONTENT');f$reciprocal_us_content_value<-40
add('repairs and U.S. content require intersection',facts=f,subtotal=0,missing='reciprocal_us_content_in_chapter98_value')
f$reciprocal_us_content_in_chapter98_value<-5;add('repair intersection priced once',facts=f,subtotal=2.5)
f$reciprocal_us_content_in_chapter98_value<-31;add('intersection cannot exceed repairs',facts=f,subtotal=0,missing=c('reciprocal_us_content_in_chapter98_value','reciprocal_us_content_value','customs_value'))
f$chapter98_provision<-'98020080';f$chapter98_us_products_value<-40;f$reciprocal_us_content_in_chapter98_value<-NULL
add('assembly U.S. components are not deducted twice',facts=f,subtotal=6,missing=character())
f$reciprocal_us_content_value<-50;add('additional qualifying U.S. content after assembly deduction',facts=f,subtotal=5)
f$reciprocal_us_content_value<-30;add('contradictory U.S. content amounts remain incomplete',facts=f,subtotal=0,missing=c('reciprocal_us_content_value','chapter98_us_products_value'))
f<-q;f$claims<-list('RECIPROCAL_TRANSIT');f$reciprocal_transit_final_vessel<-TRUE
add('transit requires actual loading window',facts=f,subtotal=0,missing='reciprocal_transit_loading_window')
f$reciprocal_transit_loading_window<-'before_initial_cutoff'
add('original vessel transit exception',facts=f,subtotal=0,codes='9903.01.28')
add('updated transit cutoff applies to May 29',bundle='late',facts=f,subtotal=0,codes='9903.01.28')
f$reciprocal_transit_final_vessel<-FALSE
add('air or transloaded transport has no vessel exception',facts=f,codes='9903.01.25')
f$reciprocal_transit_final_vessel<-TRUE;f$reciprocal_transit_loading_window<-'before_country_cutoff'
add('EU in transit is 10 rather than 20',bundle='country',facts=f,country='4279',codes='9903.01.25')
add('China pre April 9 loading is 10 rather than 84',bundle='country',facts=f,country='5700',codes='9903.01.25')
f$reciprocal_transit_loading_window<-'before_china_increase'
add('China April 9 vessel loading is 10 rather than 125',bundle='suspension',facts=f,country='5700',codes='9903.01.25')
add('April 9 loading has no same-day China relief',bundle='country',facts=f,country='5700',subtotal=84,codes='9903.01.63')
f$reciprocal_transit_loading_window<-'after_cutoffs'
add('China loaded after cutoff retains 125',bundle='suspension',facts=f,country='5700',subtotal=125)
f<-q;f$ieepa_ftz_entry<-TRUE
add('FTZ cannot inherit ordinary entry rate',facts=f,subtotal=0,error='reciprocal_ftz_admission_history_required')
add('FTZ guard precedes snapshot exemption',facts=f,hts10=products[3],subtotal=0,error='reciprocal_ftz_admission_history_required')
add('one second before June portion amendment',bundle='boundary',codes='9903.01.25')
add('June ordinary non-metal entry retains baseline',bundle='boundary',at='2025-06-04T00:01:00-04:00',subtotal=10,codes='9903.01.25',missing=character())
f<-q;f$steel_content_value<-20
add('June non-metal portion owes reciprocal duty',bundle='june_metal',hts10=products[2],at='2025-06-04T00:01:00-04:00',facts=f,subtotal=18,codes=c('9903.01.25','9903.01.33'))
add('UK actual reporting heading retains portion treatment',bundle='june_uk',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=13)
add('zero-paid U.S. metal still leaves nonmetal exposed',bundle='june_zero',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=8)
f<-q;f$aluminum_content_value<-20
add('whole-value Russian aluminum charge does not erase nonmetal exposure',bundle='june_russian',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=208)
f<-q;f$steel_content_value<-20;f$claims<-list('RECIPROCAL_US_CONTENT');f$reciprocal_us_content_value<-40
add('U.S. and metal relief requires shared-value reconciliation',bundle='june_metal',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=10,
    missing='reciprocal_us_content_in_metal_excluded_value')
f$reciprocal_us_content_in_metal_excluded_value<-20
add('U.S.-origin steel is deducted once',bundle='june_metal',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=16)
f$reciprocal_us_content_in_metal_excluded_value<-0
add('disjoint U.S. and steel values are both deducted',bundle='june_metal',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=14)
f$reciprocal_us_content_in_metal_excluded_value<-21
add('impossible U.S./steel intersection is unresolved',bundle='june_metal',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=10,
    missing=c('reciprocal_us_content_in_metal_excluded_value','reciprocal_us_content_value','customs_value'))
f<-q;f$steel_content_value<-20;f$aluminum_content_value<-30
add('mixed metals exclude their combined actual value',bundle='june_mixed',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=20)
f$aluminum_content_value<-81
add('combined metal values cannot exceed the article',bundle='june_mixed',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=15,
    missing=c('steel_content_value','aluminum_content_value','customs_value'))
f<-q;f$steel_content_value<-80;f$claims<-list('CHAPTER_98');f$chapter98_properly_claimed_and_cbp_agreed<-TRUE
f$chapter98_provision<-'98020040';f$chapter98_repairs_alterations_processing_value<-30
add('repairs require metal intersection on their own basis',bundle='june_repairs',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=10,
    missing='reciprocal_chapter98_section232_overlap_value')
f$reciprocal_chapter98_section232_overlap_value<-10
add('repairs charge excludes only evidenced metal intersection',bundle='june_repairs',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=12)
f$reciprocal_chapter98_section232_overlap_value<-9
add('impossible disjoint repair and metal values remain unresolved',bundle='june_repairs',hts10=products[2],at='2025-06-05T12:00:00-04:00',facts=f,subtotal=10,
    missing=c('reciprocal_chapter98_section232_overlap_value','customs_value'))
add('non-UK ordinary rate continues through UK sector amendment',bundle='end',at='2025-06-30T00:01:00-04:00',subtotal=10,codes='9903.01.25')
add('July 9 suspension extension preserves EU baseline',bundle='july',country='4279',at='2025-07-09T00:01:00-04:00',subtotal=10,codes='9903.01.25')
add('China separate suspension remains unchanged in July',bundle='july',country='5700',at='2025-07-20T12:00:00-04:00',subtotal=10,codes='9903.01.25')
f<-q;f$steel_content_value<-20;f$uk_civil_aircraft_gn6<-FALSE
add('UK non-aircraft retains metal and reciprocal portions',bundle='july_aircraft',country='4120',hts10=products[4],at='2025-07-10T12:00:00-04:00',facts=f,subtotal=13)
f$uk_civil_aircraft_gn6<-TRUE
add('UK qualifying aircraft removes named metal and reciprocal actions',bundle='july_aircraft',country='4120',hts10=products[4],at='2025-07-10T12:00:00-04:00',facts=f,subtotal=0,codes='9903.96.01')
add('UK aircraft before exact amendment instant retains duties',bundle='uk_aircraft_boundary',country='4120',hts10=products[4],at='2025-06-30T00:00:59-04:00',facts=f,subtotal=13)
add('UK aircraft at exact amendment instant receives relief',bundle='uk_aircraft_boundary',country='4120',hts10=products[4],at='2025-06-30T00:01:00-04:00',facts=f,subtotal=0,codes='9903.96.01')
f<-list(ieepa_ftz_entry=FALSE,uk_civil_aircraft_gn6=TRUE)
add('UK aircraft waiver does not need a modeled content value',bundle='july_aircraft',country='4120',hts10=products[4],at='2025-07-10T12:00:00-04:00',facts=f,subtotal=0,codes='9903.96.01',missing=character())
f<-q;f$steel_content_value<-20
add('unlisted UK product does not request aircraft facts',bundle='july_unlisted',country='4120',hts10=products[2],at='2025-07-10T12:00:00-04:00',facts=f,subtotal=13,missing=character())
add('before next copper amendment retains known baseline',bundle='august_boundary',at='2025-08-01T00:00:59-04:00',subtotal=10,codes='9903.01.25')
add('continued suspension at copper amendment',bundle='august_boundary',at='2025-08-01T00:01:00-04:00',subtotal=10,codes='9903.01.25')
add('new revision first minute retains old legal policy',bundle='august_new_revision',at='2025-08-07T00:00:59-04:00',subtotal=10,codes='9903.01.25')
add('new country headings require separate executable history',bundle='august_new_revision',at='2025-08-07T00:01:00-04:00',subtotal=0,codes=character())
f<-q;f$copper_content_value<-30
add('copper nonmetal portion retains reciprocal duty',bundle='august_copper',hts10=products[5],
  at='2025-08-01T00:01:00-04:00',facts=f,subtotal=22,codes=c('9903.01.25','9903.01.33'))
add('copper before exact minute retains prior product policy',bundle='august_copper',hts10=products[5],
  at='2025-08-01T00:00:59-04:00',facts=q,subtotal=0,codes='9903.01.32',missing=character())
add('copper value is only requested for a matching action',bundle='august_copper',hts10=products[1],
  at='2025-08-02T12:00:00-04:00',facts=q,subtotal=10,codes='9903.01.25',missing=character())
add('missing copper value never becomes full article or zero reciprocal',bundle='august_copper',hts10=products[5],
  at='2025-08-02T12:00:00-04:00',facts=q,subtotal=15,codes='9903.01.33',missing='copper_content_value')
f<-q;f$copper_content_value<-30;f$steel_content_value<-20
add('mixed disjoint copper and steel portions',bundle='august_mixed',hts10=products[5],
  at='2025-08-02T12:00:00-04:00',facts=f,subtotal=30,codes=c('9903.01.25','9903.01.33'))
f<-q;f$copper_content_value<-30;f$claims<-list('RECIPROCAL_US_CONTENT');f$reciprocal_us_content_value<-40
f$reciprocal_us_content_in_metal_excluded_value<-20
add('U.S. and copper value intersection is deducted once',bundle='august_copper',hts10=products[5],
  at='2025-08-02T12:00:00-04:00',facts=f,subtotal=20,codes=c('9903.01.25','9903.01.33','9903.01.34'))
f<-q;f$copper_content_value<-30;f$claims<-list('CHAPTER_98');f$chapter98_provision<-'98020050'
f$chapter98_properly_claimed_and_cbp_agreed<-TRUE;f$chapter98_repairs_alterations_processing_value<-20
f$reciprocal_chapter98_section232_overlap_value<-5
add('copper and Chapter98 repair values use their intersection',bundle='august_copper_repairs',hts10=products[5],
  at='2025-08-02T12:00:00-04:00',facts=f,subtotal=16.5,codes=c('9903.01.25','9903.01.33'))
f$reciprocal_chapter98_section232_overlap_value<-NULL
add('repair and copper overlap is required rather than assumed',bundle='august_copper_repairs',hts10=products[5],
  at='2025-08-02T12:00:00-04:00',facts=f,subtotal=15,codes='9903.01.33',missing='reciprocal_chapter98_section232_overlap_value')
f<-q;f$claims<-list('RECIPROCAL_TRANSIT');f$reciprocal_transit_final_vessel<-TRUE;f$reciprocal_transit_loading_window<-'before_initial_cutoff'
add('transit before final cutoff',bundle='boundary',at='2025-06-16T00:00:59-04:00',facts=f,subtotal=0,codes='9903.01.28')
add('transit at final cutoff',bundle='boundary',at='2025-06-16T00:01:00-04:00',facts=f,subtotal=10,codes='9903.01.25')
f<-q;f$modeled_metal_share<-0.7;f$assembly_credit<-40;f$usmca_utilization<-1
add('modeling inputs do not change shipment duties',facts=f,codes='9903.01.25')
source('src/section232_legacy.R');source('src/ieepa_fentanyl.R');source('src/section301_revision.R')
rev<-'2025_rev_13'
bundles$cross<-make(rev,extra=list(
  compile_s232_legacy_fragment(load_s232_legacy_source(rev),products),
  compile_ieepa_emergency_fragment(load_ieepa_emergency_source(rev),products),
  compile_s301_revision_fragment(load_s301_revision_source(rev,download=FALSE),products)))
f<-c(q,list(contains_steel=TRUE,steel_content_value=20,steel_processed_from_us_metal=FALSE,
  privileged_ftz_before_20250312=FALSE,privileged_ftz_before_20250604=FALSE))
add('real steel, emergency, reciprocal and Section 301 compose independently',bundle='cross',hts10=products[2],country='5700',
  at='2025-05-20T12:00:00-04:00',facts=f,subtotal=70,codes='9903.01.33')
f$claims<-list('RECIPROCAL_US_CONTENT');f$reciprocal_us_content_value<-40
add('reciprocal content claim does not reduce other authorities',bundle='cross',hts10=products[2],country='5700',
  at='2025-05-20T12:00:00-04:00',facts=f,subtotal=70,codes='9903.01.33')
bundles$july_cross<-make('2025_rev_16',extra=list(
  compile_s232_legacy_fragment(load_s232_legacy_source('2025_rev_16'),products)))
f<-c(q,list(contains_steel=TRUE,steel_content_value=20,steel_processed_from_us_metal=FALSE,
  privileged_ftz_before_20250312=FALSE,privileged_ftz_before_20250604=FALSE,uk_civil_aircraft_gn6=FALSE))
add('actual UK metal and reciprocal rules price non-aircraft portions',bundle='july_cross',hts10=products[4],country='4120',
  at='2025-07-10T12:00:00-04:00',facts=f,subtotal=13,codes=c('9903.01.25','9903.01.33'))
f$uk_civil_aircraft_gn6<-TRUE
add('actual UK aircraft waiver reevaluates the statutory metal action',bundle='july_cross',hts10=products[4],country='4120',
  at='2025-07-10T12:00:00-04:00',facts=f,subtotal=0,codes='9903.96.01')
add('UK aircraft relief does not extend to French metal articles',bundle='july_cross',hts10=products[4],country='4279',
  at='2025-07-10T12:00:00-04:00',facts=f,subtotal=18,codes=c('9903.01.25','9903.01.33'))
# Source/rule ordering and duplicate products cannot change an outcome.
b<-bundles$country;b$rules<-rev(b$rules);b$sources<-rev(b$sources)
stopifnot(identical(evaluate_shipment_bundle(b,products[1],'5700','2025-04-09T12:00:00-04:00',q)$known_subtotal,84))
if('--emit'%in%commandArgs(TRUE)) {
  out<-gzfile('tests/fixtures/shipment/ieepa-reciprocal-initial.json.gz','w')
  writeLines(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=NA),out);close(out)
}
cat('Reciprocal R/TypeScript fixtures:',length(cases),'passed\n')
