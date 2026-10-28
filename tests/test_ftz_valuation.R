source('src/helpers.R');source('src/shipment_build.R')
x<-load_shipment_base_source('2026_rev_19')
products<-c('6912004810','8211912000')
f<-compile_shipment_base_fragment(x,products,'5800')
b<-list(contract_version='sail.shipment-rules/v1',dataset_version='ftz-base-only-source-test',revision='2026_rev_19',
 evidence_snapshot_id='not-production',valid_from='2026-09-15T00:00:00-04:00',valid_until='2026-09-16T00:00:00-04:00',
 products=as.list(products),countries=list('5800'),sources=list(),rules=list(),coverage=list(),
 coverage_requirements=list('base'),fact_definitions=list(),claim_definitions=list())
seed<-b;b<-compose_shipment_rules(b,list(f));cases<-list()
q<-list(ieepa_ftz_entry=TRUE,ftz_status='nonprivileged_foreign',ftz_valuation_method='admission_transaction',
 ftz_admission_price_reasonably_representative=TRUE,ftz_admission_price=100,ftz_statutory_additions=10,
 ftz_included_international_freight_insurance=4,ftz_included_us_inland_freight=6,ftz_allowance_claimed=FALSE)
check<-function(name,facts=q,amount=9.8,missing=character(),source=NULL,hts=products[1]) {
 r<-evaluate_shipment_bundle(b,hts,'5800','2026-09-15T12:00:00-04:00',facts)
 stopifnot(abs(r$known_subtotal-amount)<1e-9,setequal(r$missing_inputs,missing))
 if(is.null(source))stopifnot(!length(r$source_errors),if(length(missing))is.null(r$complete_total) else abs(r$complete_total-amount)<1e-9)
 else stopifnot(is.null(r$complete_total),any(grepl(source,r$source_errors,fixed=TRUE)))
 cases[[length(cases)+1L]]<<-list(name=name,hts10=hts,country='5800',entry_at='2026-09-15T12:00:00-04:00',facts=facts,expected=shipment_result_for_json(r))
}
check('NPF uses admission transaction price with additions and only included transportation deducted')
v<-q;v$customs_value<-999999;check('Ordinary caller customs value cannot override the FTZ legal valuation',v)
v<-q;v$ftz_statutory_additions<-NULL;check('Absent statutory additions cannot become zero',v,0,'ftz_statutory_additions')
v<-q;v$ftz_included_international_freight_insurance<-200
check('Deductions exceeding the source value cannot become negative or zero duty',v,0,c('ftz_admission_price','ftz_statutory_additions','ftz_included_international_freight_insurance','ftz_included_us_inland_freight'))
v<-q;v$ftz_admission_price_reasonably_representative<-FALSE
check('Unavailable representative admission price requires the permitted alternative method',v,0,c('ftz_valuation_method','ftz_admission_price_reasonably_representative'))
v<-q;v$ftz_valuation_method<-'deductive_zone_value';v$ftz_admission_price_reasonably_representative<-FALSE
v$ftz_zone_sale_exists<-TRUE;v$ftz_zone_sale_price<-200;v$ftz_included_zone_processing_costs<-60;v$ftz_included_zone_general_expenses_profit<-30
check('Deductive method removes only included zone costs profit and transportation',v)
v$ftz_zone_sale_exists<-FALSE;v$ftz_zone_material_costs<-150;v$ftz_zone_processing_costs<-50
check('Without a zone sale total zone value uses material and processing cost',v)
v$ftz_admission_price_reasonably_representative<-TRUE
check('Deductive method is unavailable when representative admission price is available',v,0,c('ftz_valuation_method','ftz_admission_price_reasonably_representative'))
v<-q;v$ftz_status<-'recoverable_waste';v$ftz_valuation_method<-'recoverable_waste_sale';v$ftz_waste_sale_price<-40
v$ftz_admission_price<-v$ftz_statutory_additions<-NULL
check('Recoverable waste uses its zone seller transfer transaction',v,3.92)
v<-q;v$ftz_allowance_claimed<-TRUE;v$ftz_allowance_center_director_approved<-TRUE;v$ftz_allowance_amount<-20
check('Only approved zone damage allowance reduces the dutiable value',v,7.84)
v$ftz_allowance_center_director_approved<-FALSE
check('Unapproved allowance cannot reduce the duty',v,0,'ftz_allowance_center_director_approved')
v<-q;v$quantity_each<-10
check('NPF compound duty uses constructive-transfer quantity and legal value',v,6.44,hts=products[2])
v$quantity_each<-NULL;check('Compound quantity remains required',v,0,'quantity_each',hts=products[2])
v<-q;v$ieepa_ftz_entry<-FALSE;v$customs_value<-100
check('Ordinary entries retain their ordinary customs value and ask no FTZ details',v)
v<-q;v$ftz_status<-'privileged_foreign'
check('PF is never priced at current withdrawal ordinary rates',v,0,source='base_ftz_admission_classification_and_rate_history')
v<-q;v$ftz_status<-'domestic'
check('Domestic status needs its own merchandise and production reconciliation',v,0,source='base_ftz_domestic_status_and_production_reconciliation')
for(claim in c('USMCA','COLUMN1_SPECIAL','CHAPTER_98')) {
 v<-list(ieepa_ftz_entry=TRUE,ftz_status='nonprivileged_foreign',claims=list(claim))
 check(paste('Uncompiled FTZ',claim,'law is a source question before valuation facts'),v,0,
  source=if(claim=='USMCA')'base_ftz_preference_and_chapter98_admission_treatment' else paste0('claim_not_priced:',claim))
}
# Compiler mechanics only: explicitly contradictory legacy aliases cannot
# override the one entry-context fact. These are not legal action fixtures.
probe<-list(contract_version='sail.shipment-rule-fragment/v1',id='controlled-ftz-alias-probe',sources=f$sources,
 rules=lapply(c('s122_ftz_entry','s338_ftz_entry'),function(alias)list(id=paste0('controlled_',alias),action_id=paste0('controlled_',alias),
  authority='base',kind='duty',verification='verified',source_ids=lapply(f$sources,`[[`,'id'),when=list(fact=alias),
  formula=list(unresolved_source='controlled_canonical_ftz_guard_reached'),reporting_codes=list())),
 fact_definitions=setNames(rep(list(list(type='boolean',source_ids=lapply(f$sources,`[[`,'id'))),2),c('s122_ftz_entry','s338_ftz_entry')))
aliased<-compose_shipment_rules(seed,list(f,probe));v<-q;v$s122_ftz_entry<-v$s338_ftz_entry<-FALSE
r<-evaluate_shipment_bundle(aliased,products[1],'5800','2026-09-15T12:00:00-04:00',v)
stopifnot(any(grepl('controlled_canonical_ftz_guard_reached',r$source_errors)))
v$ieepa_ftz_entry<-FALSE;v$s122_ftz_entry<-v$s338_ftz_entry<-TRUE;v$customs_value<-100
r<-evaluate_shipment_bundle(aliased,products[1],'5800','2026-09-15T12:00:00-04:00',v)
# Adding two controlled actions correctly invalidates the old base inventory;
# neither alias may nevertheless activate its FTZ rule on an ordinary entry.
stopifnot(identical(r$source_errors,'coverage_unverified:base'),r$known_subtotal==9.8,is.null(r$complete_total))
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/ftz-valuation.json.gz','w');writeLines(jsonlite::toJSON(list(bundle=b,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'source-backed FTZ ordinary-base valuation checks and two canonical-alias probes passed; no additional-authority total is attested\n')
