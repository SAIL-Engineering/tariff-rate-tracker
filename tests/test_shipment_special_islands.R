source('src/helpers.R');source('src/shipment_build.R')
bad<-'Free (A*,AU,BH,CL,CO,D,E IL,JO,KR,MA,OM,P,PA,PE,S,SG)'
r<-list(expression=bad,source_code='40119020',source_row_index=1L)
s<-shipment_usmca_reference(r)
stopifnot(s$status=='parsed',identical(s$formula,list(value=0)),identical(s$raw,bad))
stopifnot(shipment_special_reference(r,'E')$status=='unresolved_source',shipment_special_reference(r,'IL')$status=='unresolved_source')
r$expression<-'Free (AU,BH,CL,CO,IL,JO,KR,MA,.OM,P,PA,PE,S,SG)'
stopifnot(shipment_usmca_reference(r)$status=='parsed',shipment_special_reference(r,'OM')$status=='unresolved_source')
r$expression<-'Free (BH,CL,JO,MA,OM,P,PE,SG) 7.5¢/kg (KR) See 9823.04.01-9823.04.54 (S+) See 9919.04.50, 9919.04.57, 9919.04.67 (PA (PA)'
kr<-shipment_special_reference(r,'KR')
stopifnot(kr$status=='parsed','quantity_kg'%in%names(kr$fact_definitions),shipment_usmca_reference(r)$status=='unresolved_source',shipment_special_reference(r,'PA')$status=='unresolved_source')
for(raw in c('Free (S) except certain articles','Free (S, S except specified articles)','Free (S) 2% (S)',
 'Free (S) 2% (E S)','Free (S) See 9919.04.50 (PA (S)','Free ((S))','Free (S,,KR)')) {
 r$expression<-raw;stopifnot(shipment_usmca_reference(r)$status=='unresolved_source')
}
# Native malformed published fields: retain the entire original text and source
# owner, while using only a literal independently unambiguous programme group.
x<-load_shipment_base_source('2025_basic');products<-c('4011902010','6204631110','0406909400')
refs<-compile_shipment_column1_references(x,products)
stopifnot(refs[['4011902010']]$usmca$status=='parsed',refs[['6204631110']]$usmca$status=='parsed')
native<-setNames(x$products,vapply(x$products,`[[`,character(1),'hts10'))
k<-shipment_special_reference(native[['0406909400']]$special,'KR')
stopifnot(k$status=='parsed',k$normalized_text=='7.5¢/kg')
f<-compile_shipment_base_fragment(x,products,'2010')
b<-list(contract_version='sail.shipment-rules/v1',dataset_version='native-special-base-only-not-production',revision='2025_basic',
 evidence_snapshot_id='primary-source-test',valid_from='2025-01-02T00:00:00-05:00',valid_until='2025-01-03T00:00:00-05:00',
 products=as.list(products),countries=list('2010'),sources=list(),rules=list(),coverage=list(),fact_definitions=list(),
 claim_definitions=list(),coverage_requirements=list('base'))
b<-compose_shipment_rules(b,list(f));cases<-list()
check<-function(name,hts,facts,amount=0,source=NULL) {
 r<-evaluate_shipment_bundle(b,hts,'2010','2025-01-02T12:00:00-05:00',facts)
 stopifnot(r$known_subtotal==amount,!length(r$missing_inputs))
 if(is.null(source))stopifnot(!length(r$source_errors),r$complete_total==amount) else stopifnot(is.null(r$complete_total),any(grepl(source,r$source_errors,fixed=TRUE)))
 cases[[length(cases)+1L]]<<-list(name=name,hts10=hts,country='2010',entry_at='2025-01-02T12:00:00-05:00',facts=facts,expected=shipment_result_for_json(r))
}
ordinary<-list(customs_value=100,ieepa_ftz_entry=FALSE)
preference<-c(ordinary,list(claims=list('USMCA'),usmca_origin_eligible=TRUE,usmca_properly_claimed=TRUE))
check('Native unclaimed tyre rate is unchanged','4011902010',ordinary,4)
check('An unrelated malformed SPI cannot erase literal S Free for a proper claim','4011902010',preference)
check('Native unclaimed trousers rate is unchanged','6204631110',ordinary,28.6)
check('Malformed OM punctuation does not erase independently explicit S Free','6204631110',preference)
check('A conditional S-plus reference never becomes direct S Free','0406909400',list(ieepa_ftz_entry=FALSE,claims=list('USMCA')),source='column1_usmca_special_expression')
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/special-programme-groups.json.gz','w');writeLines(jsonlite::toJSON(list(bundle=b,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat('Independent native Special programme groups resolve; malformed memberships, quota references and unknown prose remain unresolved\n')
