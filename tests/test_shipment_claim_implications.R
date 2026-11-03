# Declarative legal claim dependencies must affect every matched authority,
# preserve direction, reject cycles and carry their sources. No program names
# or rate constants are inferred by the production composer.
source('src/helpers.R');source('src/compile_shipment_rules.R')
seed<-list(contract_version='sail.shipment-rules/v1',dataset_version='claim-dependency-technical-fixture',revision='2026_rev_4',
 evidence_snapshot_id='synthetic-claim-evidence',valid_from='2026-01-01T00:00:00-05:00',valid_until='2026-10-23T00:00:00-04:00',
 products=list('8705900080'),countries=list('2010'),sources=list(),rules=list(),coverage=list(),coverage_requirements=list('base','section_232'),fact_definitions=list(),claim_definitions=list())
ids<-list('fixture-source');rids<-list('fixture-base','fixture-additional')
fragment<-list(contract_version='sail.shipment-rule-fragment/v2',required_compiler_features=list('claim_implications','rule_value_predicates'),id='claim-dependency-test',sources=list(list(id='fixture-source',
 status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/claim-dependency',citation='Synthetic claim dependency only, not legal coverage')),
 rules=list(list(id='fixture-base',action_id='fixture-base',authority='base',kind='duty',verification='verified',source_ids=ids,scope=list(hts_exact=list('8705900080')),
  formula=list(op='if',args=list(list(claim='PREFERENCE'),list(value=0),list(value=5)))),
 list(id='fixture-additional',action_id='fixture-additional',authority='section_232',kind='duty',verification='verified',source_ids=ids,scope=list(hts_exact=list('8705900080')),
  formula=list(op='if',args=list(list(op='and',args=list(list(claim='CONTENT'),list(fact='base_is_zero'))),list(value=10),list(value=7))))),coverage=list(),
 fact_definitions=list(base_is_zero=list(type='boolean',label='Matched base amount is zero',source_ids=ids)),
 derived_facts=list(base_is_zero=list(expression=list(rule_predicate=list(rule_ids=list('fixture-base'),amount_equal=0)),source_ids=ids)),
 claim_definitions=lapply(c('CONTENT','BRIDGE','PREFERENCE'),function(id)list(id=id,label=id,rule_ids=rids,source_ids=ids)),
 claim_implications=list(list(id='content-requires-bridge',claim_id='CONTENT',implies='BRIDGE',source_ids=ids),
  list(id='bridge-requires-preference',claim_id='BRIDGE',implies='PREFERENCE',source_ids=ids)))
b<-compose_shipment_rules(seed,list(fragment))
check<-function(claims,want) {
 facts<-list(claims=as.list(claims));r<-evaluate_shipment_bundle(b,'8705900080','2010','2026-06-01T12:00:00-04:00',facts)
 if(!isTRUE(all.equal(r$known_subtotal,want)))print(r[c('known_subtotal','missing_inputs','source_errors','components')])
 stopifnot(isTRUE(all.equal(r$known_subtotal,want)),is.null(r$complete_total))
}
check(character(),12);check('CONTENT',10);check('PREFERENCE',7);check('BRIDGE',7)
stopifnot(length(b$claim_implication_decisions)==2L)
reversed<-fragment;reversed$claim_implications<-c(rev(fragment$claim_implications),fragment$claim_implications[1])
stopifnot(identical(b,compose_shipment_rules(seed,list(reversed))))
reject<-function(x)stopifnot(inherits(try(compose_shipment_rules(seed,list(x)),silent=TRUE),'try-error'))
bad<-fragment;bad$claim_implications[[2]]$implies<-'CONTENT';reject(bad)
bad<-fragment;bad$claim_implications[[1]]$source_ids<-list('missing-source');reject(bad)
bad<-fragment;bad$claim_implications[[1]]$implies<-'UNREGISTERED';reject(bad)
bad<-fragment;bad$claim_implications[[1]]$claim_id<-'PREFERENCE';bad$claim_implications[[1]]$implies<-'PREFERENCE';reject(bad)
bad<-fragment;bad$derived_facts$base_is_zero$expression$rule_predicate$rule_ids<-list('missing-rule');reject(bad)
bad<-fragment;bad$contract_version<-'sail.shipment-rule-fragment/v1';reject(bad)
bad<-fragment;bad$required_compiler_features<-list('unknown-required-feature');reject(bad)
inactive<-fragment;inactive$rules[[1]]$when<-list(value=FALSE)
ib<-compose_shipment_rules(seed,list(inactive))
ir<-evaluate_shipment_bundle(ib,'8705900080','2010','2026-06-01T12:00:00-04:00',list(claims=list('CONTENT')))
stopifnot(ir$known_subtotal==7)
unknown<-fragment;unknown$rules[[1]]$formula<-list(unresolved_source='fixture-unresolved-base-expression')
ub<-compose_shipment_rules(seed,list(unknown))
ur<-evaluate_shipment_bundle(ub,'8705900080','2010','2026-06-01T12:00:00-04:00',list(claims=list('CONTENT')))
stopifnot(ur$known_subtotal==0,any(grepl('fixture-unresolved-base-expression',ur$source_errors,fixed=TRUE)))
bounded<-fragment
bounded$rules[[3]]<-list(id='claim-activation',action_id='claim-activation',authority='section_232',kind='duty',verification='verified',
 source_ids=ids,scope=list(hts_exact=list('8705900080'),from='2026-07-01T00:00:00-04:00'),formula=list(value=0),reporting_only=TRUE)
bounded$claim_definitions<-lapply(bounded$claim_definitions,function(c){c$rule_ids<-c(c$rule_ids,list('claim-activation'));c})
bounded$claim_implications[[1]]$activation_rule_ids<-list('claim-activation')
bb<-compose_shipment_rules(seed,list(bounded))
before<-evaluate_shipment_bundle(bb,'8705900080','2010','2026-06-01T12:00:00-04:00',list(claims=list('CONTENT')))
after<-evaluate_shipment_bundle(bb,'8705900080','2010','2026-08-01T12:00:00-04:00',list(claims=list('CONTENT')))
stopifnot(before$known_subtotal==12,after$known_subtotal==10)
cat('Claim dependencies, transitivity, direction, duplicate invariance and invalid-source/cycle checks passed\n')
