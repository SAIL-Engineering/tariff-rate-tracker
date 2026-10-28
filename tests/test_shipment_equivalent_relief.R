source('src/compile_shipment_rules.R')
t<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]
b<-t$bundle;b$claim_definitions<-list();b$dataset_version<-'synthetic-equivalent-relief-not-production'
zero<-function(id,fact,code)list(id=id,action_id='one_action',authority='synthetic',kind='duty',verification='verified',
 source_ids=list('synthetic'),reporting_codes=list(code),when=list(fact=fact),formula=list(value=0),equivalent_relief_group='one_action_whole_article_relief')
b$rules<-list(zero('a_relief','waiver','9900.00.01'),zero('b_relief','other_waiver','9900.00.02'),
 list(id='charge',action_id='one_action',authority='synthetic',kind='duty',verification='verified',source_ids=list('synthetic'),reporting_codes=list('9900.00.03'),formula=list(value=10),
 suppressed_when=list(op='or',args=list(list(rule_applies='a_relief'),list(rule_applies='b_relief')))),
 list(id='independent',action_id='other_action',authority='synthetic',kind='duty',verification='verified',source_ids=list('synthetic'),reporting_codes=list(),formula=list(value=7)))
b$coverage[[1]]$rule_ids<-as.list(vapply(b$rules,`[[`,character(1),'id'))
b$fact_definitions<-list(waiver=list(type='boolean'),other_waiver=list(type='boolean'));cases<-list()
check<-function(name,facts,total,missing=character(),bundle=b,error=NULL) {
 r<-evaluate_shipment_bundle(bundle,t$hts10,t$country,t$entry_at,facts)
 if(!is.null(error))stopifnot(error%in%r$source_errors,is.null(r$complete_total)) else {
  stopifnot(identical(r$complete_total,total),setequal(r$missing_inputs,missing))
  if(!is.null(total))stopifnot(r$known_subtotal==total)
 }
 cases[[length(cases)+1L]]<<-list(name=name,bundle=bundle,hts10=t$hts10,country=t$country,entry_at=t$entry_at,facts=facts,expected=shipment_result_for_json(r))
 r
}
check('One proven complete exemption does not ask about alternatives',list(waiver=TRUE),7)
check('A later proven complete exemption does not ask about an earlier alternative',list(other_waiver=TRUE),7)
check('No proven exemption retains its genuinely missing predicate',list(waiver=FALSE),NULL,'other_waiver')
check('No exemption charges the original action once',list(waiver=FALSE,other_waiver=FALSE),17)
wire<-jsonlite::fromJSON(jsonlite::toJSON(b,auto_unbox=TRUE,null='null'),simplifyVector=FALSE)
wire_result<-evaluate_shipment_bundle(wire,t$hts10,t$country,t$entry_at,list(waiver=TRUE))
stopifnot(identical(wire_result$complete_total,7),!length(wire_result$missing_inputs))
constrained<-b;constrained$fact_definitions$approval<-list(type='boolean')
constrained$rules[[1]]$input_constraints<-list(list(test=list(fact='approval'),inputs=list('approval'),label='Exemption evidence must be established'))
check('A predicate alone cannot bypass the exemption constraints',list(waiver=TRUE,other_waiver=FALSE),NULL,'approval',bundle=constrained)
check('An independently proven exemption does not need another exemption evidence',list(waiver=TRUE,other_waiver=TRUE),7,bundle=constrained)
shuffled<-b;shuffled$rules<-rev(shuffled$rules)
stopifnot(identical(evaluate_shipment_bundle(b,t$hts10,t$country,t$entry_at,list(waiver=TRUE,other_waiver=TRUE)),
 evaluate_shipment_bundle(shuffled,t$hts10,t$country,t$entry_at,list(waiver=TRUE,other_waiver=TRUE))))
bad<-b;bad$rules[[2]]$formula<-list(value=1)
check('A nonzero alternative cannot be declared equivalent relief',list(waiver=TRUE),NULL,bundle=bad,error='invalid_equivalent_relief_group')
bad<-b;bad$rules[[2]]$action_id<-'different_action'
check('A relief group cannot erase another action',list(waiver=TRUE),NULL,bundle=bad,error='invalid_equivalent_relief_group')
bad<-b;bad$rules[[2]]$when<-list(rule_applies='a_relief')
check('Relief probes cannot depend on members of their own group',list(waiver=TRUE),NULL,bundle=bad,error='invalid_equivalent_relief_group')
if('--emit'%in%commandArgs(TRUE))jsonlite::write_json(cases,'tests/fixtures/shipment/equivalent-relief.json',auto_unbox=TRUE,null='null',digits=NA)
cat(length(cases),'equivalent relief, missing facts, distinct-action and invalid-group cases passed\n')
