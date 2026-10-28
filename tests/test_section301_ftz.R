source('src/helpers.R');source('src/section301_revision.R');source('src/compile_shipment_rules.R')
products<-c('7602000075','8542310015');extraction<-load_s301_revision_source('2026_rev_19')
# H310256's2020 statistical code is retired here. The ordinary compiler must
# reject it rather than infer a valid current suffix from the same HTS8 scope.
stopifnot(inherits(try(compile_s301_revision_fragment(extraction,'7602000090'),silent=TRUE),'try-error'))
f<-compile_s301_revision_fragment(extraction,products)
b<-list(contract_version='sail.shipment-rules/v1',dataset_version='s301-ftz-components-not-production',
 revision='2026_rev_19',evidence_snapshot_id='source-only-not-production',valid_from='2026-09-15T00:00:00-04:00',
 valid_until='2026-09-16T00:00:00-04:00',products=as.list(products),countries=list('5700'),rules=list(),sources=list(),
 fact_definitions=list(),claim_definitions=list(),coverage=list(),coverage_requirements=list('base','section_301','section_232'))
b<-compose_shipment_rules(b,list(f));cases<-list()
q<-list(ieepa_ftz_entry=TRUE,ftz_status='recoverable_waste',ftz_valuation_method='recoverable_waste_sale',
 ftz_waste_sale_price=40,ftz_allowance_claimed=FALSE)
check<-function(name,facts=q,amount=10,source=NULL,missing=character(),hts=products[1]) {
 r<-evaluate_shipment_bundle(b,hts,'5700','2026-09-15T12:00:00-04:00',facts)
 stopifnot(abs(r$known_subtotal-amount)<1e-9,is.null(r$complete_total),setequal(r$missing_inputs,missing))
 e<-Filter(function(c)c$authority=='section_301',r$components)
 errors<-unique(unlist(lapply(e,`[[`,'source_errors')))
 if(!is.null(source))stopifnot(any(grepl(source,errors,fixed=TRUE))) else stopifnot(!length(errors))
 cases[[length(cases)+1L]]<<-list(name=name,hts10=hts,country='5700',entry_at='2026-09-15T12:00:00-04:00',facts=facts,expected=shipment_result_for_json(r))
}
check('Recoverable scrap uses current NPF classification and waste transfer value, not original foil value')
v<-q;v$customs_value<-999999;check('Caller ordinary value cannot override NPF additional-duty valuation',v)
v<-q;v$ftz_waste_sale_price<-NULL;check('Missing waste sale value is not zero duty',v,0,missing='ftz_waste_sale_price')
v<-q;v$ftz_status<-'privileged_foreign';v$customs_value<-100
check('PF cannot inherit current withdrawal rate or inflate known subtotal',v,0,source='section301_pf_admission_classification_and_rate_history')
v<-q;v$ftz_status<-NULL;check('Unspecified FTZ status cannot become ordinary current rate',v,0,missing='ftz_status')
v<-q;v$ieepa_ftz_entry<-FALSE;v$customs_value<-100
check('Ordinary entry continues to use ordinary customs value',v,25)
v<-list(customs_value=100)
check('Missing ordinary-versus-FTZ context cannot price a PF assumption',v,0,missing='ieepa_ftz_entry')
v<-list(ieepa_ftz_entry=TRUE,ftz_status='nonprivileged_foreign',ftz_valuation_method='admission_transaction',
 ftz_admission_price_reasonably_representative=TRUE,ftz_admission_price=100,ftz_statutory_additions=10,
 ftz_included_international_freight_insurance=4,ftz_included_us_inland_freight=6,ftz_allowance_claimed=FALSE)
check('NPF semiconductor current additional rate uses its separate FTZ value',v,50,hts=products[2])
v$claims<-list('CHAPTER_98')
check('Uncompiled FTZ Chapter98 interaction remains a source question before entitlement/value facts',v,0,
 source='section301_ftz_chapter98_admission_and_entry_treatment',hts=products[2])
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/section301-ftz.json.gz','w');writeLines(jsonlite::toJSON(list(bundle=b,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'Section301 FTZ current-classification, value and admission-history regressions passed; not an all-authority total\n')
