suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/section232_legacy.R');source('src/compile_shipment_rules.R')
snapshot<-'tests/fixtures/section232_grants/snapshot.json'
make<-function(rev,emergency=FALSE) {
 f<-compile_s232_legacy_fragment(load_s232_legacy_source(rev),c('7208101500','7604101000'),snapshot)
 b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
 b$rules<-list();b$coverage<-list();b$claim_definitions<-list();b$fact_definitions<-list()
 b$products<-list('7208101500','7604101000');b$countries<-as.list(as.character(read.csv('resources/census_codes.csv')$Code))
 b$valid_from<-f$supported_from;b$valid_until<-f$supported_until;b$coverage_requirements<-list('section_232')
 b$revision<-rev;b$dataset_version<-'synthetic-grants-not-release'
 if(emergency) {
   b$rules<-list(list(id='synthetic_mexico_emergency',action_id='synthetic_mexico_emergency',authority='ieepa_fentanyl',kind='duty',verification='verified',
    scope=list(hts_exact=list('7208101500'),countries=list('2010')),source_ids=list(b$sources[[1]]$id),
    reporting_codes=list('9903.01.01'),when=list(op='not',args=list(list(claim='USMCA'))),formula=list(value=25)))
   b$claim_definitions<-list(list(id='USMCA',label='USMCA',source_ids=list(b$sources[[1]]$id),rule_ids=list('synthetic_mexico_emergency')))
 }
 compose_shipment_rules(b,list(f))
}
bundles<-list(january=make('2025_basic'),march=make('2025_rev_4'),june=make('2025_rev_14',TRUE))
grantfacts<-function(id='TEST_STEEL') {
 p<-paste0('s232_grant_',id,'_')
 c(list(customs_value=100,claims=list(paste0('section232:grant:',id))),
   setNames(list('Synthetic Importer',TRUE,10,90,TRUE),paste0(p,c('importer','product_matches','entry_quantity','used_quantity','utilization_verified'))))
}
cases<-list()
add<-function(name,facts,subtotal,codes=character(),missing=character(),error=NULL,hts='7208101500',country='5700',period='january',entry='2025-01-16T12:00:00-05:00') {
 cases[[length(cases)+1L]]<<-list(name=name,bundle=period,hts10=hts,country=country,entry_at=entry,facts=facts,
 expected=list(known_subtotal=subtotal,applied_codes=as.list(sort(codes)),missing_inputs=as.list(sort(missing)),source_error=error))
}
q<-grantfacts()
add('verified decision and reconciled quantity waive only metal duty',q,0)
add('exact activation boundary applies',q,0,entry='2025-01-15T00:00:00-05:00')
add('superseded decision applies before correction instant',grantfacts('TEST_CORRECTED'),0,entry='2025-01-20T12:29:59-05:00')
add('superseded decision stops between HTS revisions',grantfacts('TEST_CORRECTED'),25,'9903.80.01',error='grant_claim_outside_verified',entry='2025-01-20T12:30:00-05:00')
add('revoked decision stops at source instant',grantfacts('TEST_REVOKED'),25,'9903.80.01',error='grant_claim_outside_verified',entry='2025-01-21T09:00:00-05:00')
add('no grant relief before activation in at-entry calculation',q,25,'9903.80.01',error='grant_claim_outside_verified',entry='2025-01-14T23:59:59-05:00')
q$s232_grant_TEST_STEEL_importer<-'Other importer'
add('wrong party cannot use a grant',q,0,missing='s232_grant_TEST_STEEL_importer')
q<-grantfacts();q$s232_grant_TEST_STEEL_product_matches<-FALSE
add('same HTS but wrong product cannot use a grant',q,0,missing='s232_grant_TEST_STEEL_product_matches')
q<-grantfacts();q$s232_grant_TEST_STEEL_used_quantity<-91
add('partially covered line must be split',q,0,missing=c('s232_grant_TEST_STEEL_entry_quantity','s232_grant_TEST_STEEL_used_quantity'))
q<-grantfacts();q$s232_grant_TEST_STEEL_used_quantity<-NULL
add('missing utilization cannot waive duty',q,0,missing='s232_grant_TEST_STEEL_used_quantity')
q<-grantfacts();q$s232_grant_TEST_STEEL_utilization_verified<-FALSE
add('unreconciled utilization cannot waive duty',q,0,missing='s232_grant_TEST_STEEL_utilization_verified')
q<-grantfacts()
add('grant bypasses irrelevant Mexico melt questions',q,0,country='2010')
add('EU grant requires no metal reporting heading',q,0,country='4759')
add('Japan grant requires exclusion heading',q,0,'9903.81.80',country='5880')
add('ordinary activated grant survives March change',q,0,period='march',entry='2025-03-13T12:00:00-04:00')
q<-grantfacts('TEST_STX')
add('STX effective until arrangement ends',q,0,country='4759',period='march',entry='2025-03-12T00:00:59-04:00')
q$privileged_ftz_before_20250312<-FALSE
add('STX does not survive March termination',q,25,'9903.81.87',error='grant_claim_outside_verified',country='4759',period='march',entry='2025-03-12T00:01:00-04:00')
q<-grantfacts('TEST_ALUMINUM');q$aluminum_primary_smelted_or_cast_russia<-FALSE
add('ordinary aluminum grant',q,0,hts='7604101000')
q$aluminum_primary_smelted_or_cast_russia<-TRUE;q$privileged_ftz_before_20230410<-FALSE
add('ordinary grant cannot waive Russian aluminum action',q,200,'9903.85.67',hts='7604101000',error='grant_claim_outside_verified')
q<-grantfacts('TEST_RUSSIAN');q$aluminum_primary_smelted_or_cast_russia<-TRUE
add('separately established Russian action authorization',q,0,hts='7604101000')
q<-list(customs_value=100,steel_content_value=100,privileged_ftz_before_20250312=FALSE,privileged_ftz_before_20250604=FALSE)
add('positive metal duty suppresses emergency after June amendment',q,50,'9903.81.87',country='2010',period='june',entry='2025-06-05T12:00:00-04:00')
q<-grantfacts()
add('grant removal of metal duty revives Mexico emergency',q,25,'9903.01.01',country='2010',period='june',entry='2025-06-05T12:00:00-04:00')
q$claims<-c(q$claims,list('USMCA'))
add('USMCA and grant reevaluate both actions',q,0,country='2010',period='june',entry='2025-06-05T12:00:00-04:00')
for(c in cases) {
 r<-evaluate_shipment_bundle(bundles[[c$bundle]],c$hts10,c$country,c$entry_at,c$facts)
 codes<-sort(unique(unlist(lapply(Filter(function(x)x$status=='applied',r$components),`[[`,'reporting_codes'))))
 if(abs(r$known_subtotal-c$expected$known_subtotal)>1e-9 || !setequal(codes,unlist(c$expected$applied_codes)) ||
    !setequal(r$missing_inputs,unlist(c$expected$missing_inputs)) || (!is.null(c$expected$source_error)&&!any(grepl(c$expected$source_error,r$source_errors)))) {
  print(list(case=c$name,got=r[c('known_subtotal','missing_inputs','source_errors')],codes=codes,expected=c$expected));stop('Grant decision regression')
 }
 stopifnot(is.null(r$complete_total),r$status=='unresolved_source')
}
# Source snapshots never attest all-authority coverage. Preserve evidence pinning
# and ordinary amounts when no claim is made, regardless of grant model inputs.
r<-evaluate_shipment_bundle(bundles$january,'7208101500','5700','2025-01-16T12:00:00-05:00',list(customs_value=100))
stopifnot(r$known_subtotal==25,!length(r$missing_inputs))
if('--emit' %in% commandArgs(trailingOnly=TRUE)) jsonlite::write_json(list(bundles=bundles,cases=cases),
 'tests/fixtures/shipment/commerce-grants.json',auto_unbox=TRUE,null='null',digits=NA)
cat(length(cases),'synthetic grant decisions against real archived metal rules passed\n')
