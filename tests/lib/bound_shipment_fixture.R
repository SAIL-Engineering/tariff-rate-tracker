# Bound source-compiled fixtures to the test bundle's declared origin universe.
# This does not change any legal predicate/rate. Keep transitive dependencies
# intact and fail if a retained expression references a discarded own rule.
bound_shipment_fixture_countries <- function(fragment,countries) {
  all_ids<-vapply(fragment$rules,`[[`,character(1),'id')
  kept<-Filter(function(r)is.null(r$scope$countries)||length(intersect(unlist(r$scope$countries),countries))>0L,fragment$rules)
  ids<-vapply(kept,`[[`,character(1),'id');discarded<-setdiff(all_ids,ids)
  refs<-function(node)if(!is.list(node))character() else c(node$rule_applies,node$rule_amount,unlist(lapply(node,refs),use.names=FALSE))
  stopifnot(!any(unlist(lapply(kept,function(r)refs(list(r$when,r$suppressed_when,r$formula,r$input_constraints))))%in%discarded))
  fragment$rules<-kept
  fragment$claim_definitions<-Filter(function(c)length(c$rule_ids)>0L,lapply(fragment$claim_definitions,function(c) {
    c$rule_ids<-as.list(intersect(unlist(c$rule_ids),ids))
    if(!is.null(c$candidate_rule_ids))c$candidate_rule_ids<-as.list(intersect(unlist(c$candidate_rule_ids),ids))
    c
  }))
  fragment$unchanged_claims<-Filter(function(c)length(c$target_rule_ids)>0L,lapply(fragment$unchanged_claims,function(c) {
    c$target_rule_ids<-as.list(intersect(unlist(c$target_rule_ids),ids));c
  }))
  fragment
}
