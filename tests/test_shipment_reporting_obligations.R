source('src/helpers.R');source('src/compile_shipment_rules.R')
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
s<-list(id='reporting-fixture',status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/reporting',citation='Synthetic distinction between monetary suppression and reporting')
b$sources<-list(s);b$rules<-list();b$coverage_requirements<-list('unverified-other-authority');b$coverage<-list();b$claim_definitions<-list();b$fact_definitions<-list()
r<-function(id,amount,code,reporting=FALSE)list(id=id,action_id=id,authority='synthetic',kind='duty',verification='verified',source_ids=list(s$id),
 when=list(value=TRUE),formula=list(value=amount),reporting_codes=list(code),reporting_only=reporting)
f<-list(id='reporting-fixture',sources=list(s),rules=list(r('charge',25,'9903.79.01'),r('exemption-report',0,'9903.01.33',TRUE),r('ordinary-charge',10,'9903.01.25')),
 relations=list(list(id='monetary-priority',effect='suppress',when_rule_applies='charge',target_reporting_codes=list('9903.01.33','9903.01.25'),preserve_reporting_only=TRUE,source_ids=list(s$id))),coverage=list())
x<-compose_shipment_rules(b,list(f));at<-x$valid_from
result<-evaluate_shipment_bundle(x,unlist(x$products)[1],unlist(x$countries)[1],at,list())
byid<-setNames(result$components,vapply(result$components,`[[`,character(1),'rule_id'))
stopifnot(byid[['charge']]$status=='applied',byid[['ordinary-charge']]$status=='suppressed',
 byid[['exemption-report']]$status=='applied',byid[['exemption-report']]$amount==0,result$known_subtotal==25)
# A positive formula cannot masquerade as a reporting obligation.
bad<-f;bad$rules[[2]]$formula<-list(value=1)
failed<-tryCatch({compose_shipment_rules(b,list(bad));FALSE},error=function(e)grepl('reporting',conditionMessage(e),ignore.case=TRUE))
stopifnot(failed)
# The audit trail records retention only for targets actually selected by the
# relation. A reporting-code match alone cannot bypass its rule-id restriction.
restricted<-f;restricted$relations[[1]]$target_rule_ids<-list('ordinary-charge')
selected<-compose_shipment_rules(b,list(restricted))
stopifnot(!any(vapply(selected$relation_decisions,function(d)identical(d$effect,'reporting_obligation_retained'),logical(1))))
# Other actions retain their explicit suppression semantics by default.
f$relations[[1]]$preserve_reporting_only<-FALSE
old<-compose_shipment_rules(b,list(f));r0<-evaluate_shipment_bundle(old,unlist(old$products)[1],unlist(old$countries)[1],at,list())
stopifnot('exemption-report' %in% r0$suppressed_rules)
cat('Monetary suppression retains separately identified zero-duty reporting obligations\n')
