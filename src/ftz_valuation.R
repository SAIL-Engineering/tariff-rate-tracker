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
