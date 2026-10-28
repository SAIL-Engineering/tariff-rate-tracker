# 19CFR146.65(b): source valuation, independent of economic shares and ordinary
# entry transaction value. Classification and action-specific rate clocks are
# separate decisions; this module cannot attest them by computing a value.
compile_ftz_valuation <- function(root=here::here()) {
 path<-file.path(root,'resources/legal_evidence/ftz/sources.json')
 manifest<-jsonlite::fromJSON(path,simplifyVector=FALSE)
 ids<-c('ECFR-19-146.65-20261022','ECFR-19-146.42-20261022','CFR-2025-19-146.65')
 selected<-lapply(ids,function(id) {
  matches<-Filter(function(s)identical(s$id,id),manifest$sources)
  if(length(matches)!=1L)stop('Missing unique FTZ primary source: ',id)
  s<-matches[[1]];p<-file.path(root,s$path)
  if(!file.exists(p)||!identical(digest::digest(file=p,algo='sha256'),s$sha256))stop('Changed FTZ primary source: ',id)
  s$path<-normalizePath(p);s
 })
 sources<-lapply(selected,function(s)c(s[c('id','sha256','url','citation')],list(status='verified')))
 artifacts<-lapply(selected,function(s)list(source_id=s$id,path=s$path,sha256=s$sha256))
 facts<-list();v<-function(x)list(value=x);o<-function(op,...)list(op=op,args=list(...))
 f<-function(name,label,type='number',enum=NULL) {
  d<-list(type=type,label=label,source_ids=as.list(ids))
  if(type=='number')d<-c(d,list(minimum=0,unit='USD'))
  if(!is.null(enum))d$enum<-as.list(enum)
  facts[[name]]<<-d;list(fact=name)
 }
 status<-f('ftz_status','Customs status of the merchandise being transferred','string',
  c('privileged_foreign','nonprivileged_foreign','recoverable_waste','domestic'))
 method<-f('ftz_valuation_method','Applicable dutiable valuation method under 19CFR146.65(b)(2)','string',
  c('admission_transaction','deductive_zone_value','recoverable_waste_sale'))
 representative<-f('ftz_admission_price_reasonably_representative',
  'An admission transaction price and its statutory additions are available and reasonably represented','boolean')
 admission<-f('ftz_admission_price','Price paid or payable in the transaction causing zone admission')
 additions<-f('ftz_statutory_additions','Statutory additions under 19USC1401a(b)(1) to the admission transaction')
 international<-f('ftz_included_international_freight_insurance','International shipment and insurance costs included in the selected gross value')
 inland<-f('ftz_included_us_inland_freight','US inland freight costs included in the selected gross value')
 sale<-f('ftz_zone_sale_exists','A price paid or payable exists in the transaction causing transfer from the zone','boolean')
 sale_price<-f('ftz_zone_sale_price','Price paid or payable to the zone seller in the transfer transaction')
 materials<-f('ftz_zone_material_costs','Costs of all materials in the merchandise transferred from the zone')
 processing<-f('ftz_zone_processing_costs','Zone processing costs in the merchandise transferred from the zone')
 zone<-o('if',sale,sale_price,o('add',materials,processing))
 included_processing<-f('ftz_included_zone_processing_costs','Processing or fabrication costs included in total zone value')
 expenses<-f('ftz_included_zone_general_expenses_profit','Zone general expenses and profit included in total zone value')
 scrap<-f('ftz_waste_sale_price','Price paid or payable to the zone seller causing recoverable waste transfer')
 is_method<-function(m)o('eq',method,v(m))
 waste<-o('eq',status,v('recoverable_waste'))
 transaction<-o('subtract',o('add',admission,additions),o('add',international,inland))
 deductive<-o('subtract',zone,o('add',included_processing,expenses,international,inland))
 gross<-o('if',is_method('admission_transaction'),transaction,o('if',is_method('deductive_zone_value'),deductive,scrap))
 allowance<-f('ftz_allowance_claimed','A damage deterioration or casualty allowance is claimed under 19CFR146.65(b)(3)','boolean')
 approval<-f('ftz_allowance_center_director_approved','The Center director approved the claimed allowance under part158','boolean')
 allowance_value<-f('ftz_allowance_amount','Approved allowance in dutiable value')
 formula<-o('if',allowance,o('subtract',gross,allowance_value),gross)
 constraint<-function(test,inputs,label)list(test=test,inputs=as.list(inputs),label=label)
 constraints<-list(
  constraint(o('eq',waste,is_method('recoverable_waste_sale')),c('ftz_status','ftz_valuation_method'),
   'Recoverable waste under146.42(b) has its separate transaction valuation; ordinary NPF merchandise does not use that method'),
  constraint(o('if',is_method('admission_transaction'),representative,v(TRUE)),c('ftz_valuation_method','ftz_admission_price_reasonably_representative'),
   'The admission transaction method requires a reasonably represented price and additions'),
  constraint(o('if',is_method('deductive_zone_value'),o('not',representative),v(TRUE)),c('ftz_valuation_method','ftz_admission_price_reasonably_representative'),
   'The deductive alternative requires no admission price or no reasonable representation of it or its additions'),
  constraint(o('if',is_method('admission_transaction'),o('gte',transaction,v(0)),v(TRUE)),
   c('ftz_admission_price','ftz_statutory_additions','ftz_included_international_freight_insurance','ftz_included_us_inland_freight'),
   'Included transportation deductions cannot exceed admission transaction price plus statutory additions'),
  constraint(o('if',is_method('deductive_zone_value'),o('gte',deductive,v(0)),v(TRUE)),
   c('ftz_zone_sale_price','ftz_zone_material_costs','ftz_zone_processing_costs','ftz_included_zone_processing_costs','ftz_included_zone_general_expenses_profit','ftz_included_international_freight_insurance','ftz_included_us_inland_freight'),
   'Only included costs may be excluded and their sum cannot exceed total zone value'),
  constraint(o('if',allowance,approval,v(TRUE)),'ftz_allowance_center_director_approved','A claimed allowance requires Center director approval'),
  constraint(o('if',allowance,o('lte',allowance_value,gross),v(TRUE)),'ftz_allowance_amount','An approved allowance cannot exceed dutiable value'))
 list(formula=formula,constraints=constraints,fact_definitions=facts,sources=sources,source_artifacts=artifacts,
  compiler_sha256=digest::digest(file=file.path(root,'src/ftz_valuation.R'),algo='sha256'))
}

# Apply the current-classification clock only to ordinary/NPF merchandise.
# The caller must substantiate that clock for its action; PF history is not
# made current by this valuation transform. Generated AST stays interpreter-
# neutral, and no aggregate or supplied ordinary value can override FTZ value.
compile_current_npf_context <- function(fragment,pf_question,chapter98_question,root=here::here()) {
 ftz<-compile_ftz_valuation(root);ids<-vapply(ftz$sources,`[[`,character(1),'id')
 flag<-list(fact='ieepa_ftz_entry');status<-list(fact='ftz_status')
 npf<-list(op='or',args=lapply(c('nonprivileged_foreign','recoverable_waste'),function(s)
  list(op='eq',args=list(status,list(value=s)))))
 current<-list(op='and',args=list(flag,npf,list(op='not',args=list(list(claim='CHAPTER_98')))))
 question<-function(s)list(unresolved_source=s)
 replace<-function(node) {
  if(identical(node,list(fact='customs_value')))return(list(op='if',args=list(flag,ftz$formula,node)))
  if(is.list(node))lapply(node,replace) else node
 }
 consumes_value<-function(node) {
  if(identical(node,list(fact='customs_value')))return(TRUE)
  is.list(node)&&any(vapply(node,consumes_value,logical(1)))
 }
 fragment$rules<-lapply(fragment$rules,function(r) {
  prior<-r$when %||% list(value=TRUE)
  r$when<-list(op='if',args=list(flag,list(op='if',args=list(npf,
   list(op='if',args=list(list(claim='CHAPTER_98'),question(chapter98_question),prior)),question(pf_question))),prior))
  needs_value<-consumes_value(list(r$formula,r$input_constraints))
  r$formula<-replace(r$formula);r$input_constraints<-lapply(r$input_constraints,replace)
  if(needs_value)for(c in ftz$constraints) {
   c$test<-list(op='if',args=list(current,c$test,list(value=TRUE)))
   r$input_constraints[[length(r$input_constraints)+1L]]<-c
  }
  r$source_ids<-as.list(sort(unique(c(unlist(r$source_ids),ids))))
  r
 })
 fragment$sources<-c(fragment$sources,ftz$sources);fragment$source_artifacts<-c(fragment$source_artifacts,ftz$source_artifacts)
 fragment$fact_definitions$ieepa_ftz_entry<-list(type='boolean',label='Entry from a foreign trade zone',source_ids=as.list(ids))
 for(k in names(ftz$fact_definitions)) {
  old<-fragment$fact_definitions[[k]]
  if(!is.null(old)&&!identical(old,ftz$fact_definitions[[k]]))stop('Conflicting FTZ action input: ',k)
  fragment$fact_definitions[[k]]<-ftz$fact_definitions[[k]]
 }
 fragment$compiler_dependencies$ftz_valuation<-ftz$compiler_sha256
 fragment$ftz_context<-list(mode='ordinary_or_npf_current_classification',source_ids=as.list(ids),
  privileged_foreign_question=pf_question,chapter98_question=chapter98_question)
 fragment
}
