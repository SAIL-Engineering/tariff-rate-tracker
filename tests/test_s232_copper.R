source('src/helpers.R');source('src/compile_shipment_rules.R');source('src/section232_copper.R')
products<-c('7408113000','7412200015','8544429090','8544493080','7413009000')
f<-compile_s232_copper_fragment('2026_rev_4',products)
b<-list(contract_version='sail.shipment-rules/v1',dataset_version='source-copper-components-not-production',revision='2026_rev_4',
 evidence_snapshot_id='primary-copper-test',valid_from=f$supported_from,valid_until=f$supported_until,
 products=as.list(products),countries=list('5700','1220','2010','5880','4279'),sources=list(),rules=list(),coverage=list(),
 coverage_requirements=list('base','section_232','section_301','ieepa_reciprocal','adcvd'),fact_definitions=list(),claim_definitions=list())
b<-compose_shipment_rules(b,list(f));cases<-list();extra_bundles<-list()
q<-list(ieepa_ftz_entry=FALSE,customs_value=100,contains_copper=TRUE,s232_copper_only_material=FALSE,
 copper_value_determination='substantiated',declared_copper_content_value=20)
add<-function(name,facts=q,amount=10,codes=c('9903.78.01','9903.78.02'),missing=character(),source=NULL,
 at='2026-03-01T12:00:00-05:00',hts=products[1],country='5700') {
 r<-evaluate_shipment_bundle(b,hts,country,at,facts)
 got<-sort(unique(unlist(lapply(Filter(function(c)c$status=='applied',r$components),`[[`,'reporting_codes'))))
 if(r$known_subtotal!=amount||!setequal(r$missing_inputs,missing)||!setequal(got,codes)) {
  print(list(name=name,result=r[c('known_subtotal','missing_inputs','source_errors')],codes=got));stop('Copper source decision regression')
 }
 stopifnot(is.null(r$complete_total))
 if(!is.null(source))stopifnot(any(grepl(source,r$source_errors,fixed=TRUE)))
 cases[[length(cases)+1L]]<<-list(name=name,hts10=hts,country=country,entry_at=at,facts=facts,expected=shipment_result_for_json(r))
}
add('Substantiated copper value prices only the actual content')
for(country in unlist(b$countries))add(paste('universal original scope',country),country=country)
for(hts in products[1:3])add(paste('native copper scope',hts),hts=hts)
add('Unlisted neighbouring statistical branch',facts=structure(list(),names=character()),hts=products[4],amount=0,codes=character())
v<-q;v$declared_copper_content_value<-NULL
add('Omitted content value is not a declared inability to determine it',v,0,character(),missing='declared_copper_content_value')
v<-q;v$copper_value_determination<-NULL
add('Missing documentary state cannot silently select full entered value',v,0,character(),missing='copper_value_determination')
v<-q;v$copper_value_determination<-'cannot_be_determined';v$declared_copper_content_value<-NULL
add('CBP expressly requires full value for an unascertainable copper value',v,50,'9903.78.01')
v$copper_value_determination<-'insufficient_documentation'
add('CBP expressly requires full value when documentation is insufficient',v,50,'9903.78.01')
v<-q;v$s232_copper_only_material<-TRUE;v$declared_copper_content_value<-NULL;v$copper_value_determination<-NULL
add('Only-copper article needs no estimated metal fraction',v,50,'9903.78.01')
v<-list(ieepa_ftz_entry=FALSE,contains_copper=FALSE)
add('Copper-free listed article has the sourced zero reporting role',v,0,'9903.78.02')
v<-q;v$declared_copper_content_value<-120
add('Excessive content value requires corrected inputs',v,0,character(),missing=c('customs_value','declared_copper_content_value'))
v<-q;v$ieepa_ftz_entry<-NULL
add('Unspecified FTZ context is not an ordinary entry',v,0,character(),missing='ieepa_ftz_entry')
v<-q;v$ieepa_ftz_entry<-TRUE
add('FTZ history precedes both amount and current reporting exemption',v,0,character(),source='copper_ftz_admission')
v$contains_copper<-FALSE
add('Copper-free current article cannot settle privileged admission history',v,0,character(),source='copper_ftz_admission')
v<-q;v$claims<-list('USMCA')
add('Preference claim does not remove the copper action',v)
v<-q;v$claims<-list('CHAPTER_98')
add('Uncompiled Chapter98 applicability cannot establish a downstream copper exemption',v,0,character(),source='copper_selected_chapter98')
add('Before original effective minute',at='2025-08-01T00:00:59-04:00',amount=0,codes=character())
add('At original effective minute',at='2025-08-01T00:01:00-04:00')
add('Before April replacement minute',at='2026-04-06T00:00:59-04:00')
add('At April replacement minute',at='2026-04-06T00:01:00-04:00',amount=0,codes=character(),source='outside_bundle_interval')
v<-q;v$copper_share<-.01;v$assembly_credit<-10000;v$modeled_s232_rate<-.99
add('Economic shares and credits cannot change liability',v)
shuffled<-b;shuffled$rules<-c(rev(b$rules),b$rules[1])
stopifnot(identical(evaluate_shipment_bundle(b,products[1],'5700','2026-03-01T12:00:00-05:00',q),
 evaluate_shipment_bundle(shuffled,products[1],'5700','2026-03-01T12:00:00-05:00',q)))
# Real source actions under an explicitly synthetic complete-232 assumption.
# This isolates the valuation interaction. It is not a production coverage proof.
source('src/ieepa_reciprocal_revision.R')
rf<-compile_reciprocal_initial_fragment(load_reciprocal_scope('2025_rev_17'),products)
seed<-list(contract_version='sail.shipment-rules/v1',dataset_version='conditional-copper-reciprocal-not-release',revision='2025_rev_17',
 evidence_snapshot_id='controlled-coverage-assumption',valid_from=rf$supported_from,valid_until=rf$supported_until,
 products=as.list(products),countries=list('4279'),rules=list(),sources=list(),coverage=list(),fact_definitions=list(),claim_definitions=list(),
 coverage_requirements=list('base','section_232','ieepa_reciprocal'))
cf<-compile_s232_copper_fragment('2025_rev_17',products)
controlled<-compose_shipment_rules(seed,list(cf,rf))
sid<-'synthetic-complete-232-for-conditional-test'
controlled$sources[[length(controlled$sources)+1L]]<-list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),
 url='https://example.invalid/controlled-coverage',citation='Synthetic no-other-232 assumption for a technical composition test; not production legal coverage')
controlled$coverage<-list(list(authority='section_232',status='verified',determination='rules',source_ids=list(sid),rule_ids=lapply(cf$rules,`[[`,'id')))
extra_bundles$conditional<-controlled
for(mode in c('substantiated','cannot_be_determined','no_copper')) {
 v<-q;v$copper_content_value<-99
 v$ieepa_personal_accompanied_baggage<-v$ieepa_qualifying_humanitarian_donation<-v$ieepa_informational_material<-v$ieepa_de_minimis_claimed<-FALSE
 if(mode=='cannot_be_determined'){v$copper_value_determination<-mode;v$declared_copper_content_value<-NULL}
 if(mode=='no_copper')v$contains_copper<-FALSE
 r<-evaluate_shipment_bundle(controlled,products[1],'4279','2025-08-02T12:00:00-04:00',v)
 stopifnot(r$known_subtotal==switch(mode,substantiated=18,cannot_be_determined=50,no_copper=10),is.null(r$complete_total))
 cases[[length(cases)+1L]]<-list(name=paste('Conditional real-action copper/reciprocal',mode),bundle='conditional',
  hts10=products[1],country='4279',entry_at='2025-08-02T12:00:00-04:00',facts=v,expected=shipment_result_for_json(r))
}
v<-q;v$claims<-list('CHAPTER_98');v$chapter98_provision<-'98020050'
v$chapter98_properly_claimed_and_cbp_agreed<-TRUE;v$chapter98_repairs_alterations_processing_value<-40
v$reciprocal_chapter98_section232_overlap_value<-10
v$ieepa_personal_accompanied_baggage<-v$ieepa_qualifying_humanitarian_donation<-v$ieepa_informational_material<-v$ieepa_de_minimis_claimed<-FALSE
r<-evaluate_shipment_bundle(controlled,products[1],'4279','2025-08-02T12:00:00-04:00',v)
stopifnot(r$known_subtotal==0,is.null(r$complete_total),any(grepl('copper_selected_chapter98',r$source_errors,fixed=TRUE)))
cases[[length(cases)+1L]]<-list(name='Pending copper Chapter98 applicability cannot discount another action',bundle='conditional',
 hts10=products[1],country='4279',entry_at='2025-08-02T12:00:00-04:00',facts=v,expected=shipment_result_for_json(r))
# Aircraft scope has one actual copper product. Its country/date predicates and
# independent suppression relation are reused without a numeric-rate shortcut.
source('src/section232_civil_aircraft.R')
af<-compile_s232_civil_aircraft_fragment('2026_rev_4',products)
seed$dataset_version<-'copper-civil-source-test';seed$revision<-'2026_rev_4'
seed$valid_from<-'2026-03-01T00:00:00-05:00';seed$valid_until<-'2026-03-02T00:00:00-05:00'
aircraft<-compose_shipment_rules(seed,list(f,af));extra_bundles$aircraft<-aircraft
for(eligible in c(TRUE,FALSE)) {
 v<-q;v$reciprocal_partner_civil_aircraft_gn6_excluding_unmanned<-eligible
 r<-evaluate_shipment_bundle(aircraft,'7413009000','4279','2026-03-01T12:00:00-05:00',v)
 stopifnot(r$known_subtotal==if(eligible)0 else 10,is.null(r$complete_total))
 cases[[length(cases)+1L]]<-list(name=paste('Source-defined EU copper aircraft treatment',eligible),bundle='aircraft',hts10='7413009000',country='4279',
  entry_at='2026-03-01T12:00:00-05:00',facts=v,expected=shipment_result_for_json(r))
}
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/copper.json.gz','w')
 writeLines(jsonlite::toJSON(list(bundle=b,extra_bundles=extra_bundles,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'source-backed copper value, scope, reporting, claim and boundary cases passed\n')
