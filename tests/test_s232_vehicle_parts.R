source('src/helpers.R');source('src/compile_shipment_rules.R');source('src/section232_mhd_parts.R');source('src/section232_autos.R');source('src/section232_copper.R')
products<-c('4009120020','4009120050','8544429090','7320106015')
f<-compile_s232_mhd_parts_fragment('2026_rev_4',products)
a<-compile_s232_autos_fragment('2026_rev_4',products,c('2010','4120','4279','5880','5800','5830'),native_interactions=FALSE)
copper<-compile_s232_copper_fragment('2026_rev_4',products)
seed<-list(contract_version='sail.shipment-rules/v1',dataset_version='vehicle-parts-source-test-not-release',revision='2026_rev_4',
 evidence_snapshot_id='original-vehicle-annexes',valid_from='2025-01-01T00:00:00-05:00',valid_until=copper$supported_until,
 products=as.list(products),countries=list('2010','4120','4279','5880','5800','5830'),sources=list(),rules=list(),coverage=list(),
 coverage_requirements=list('base','section_232','ieepa_reciprocal','adcvd'),fact_definitions=list(),claim_definitions=list())
b<-compose_shipment_rules(seed,list(f,a,copper))
cases<-list();bundles<-list();prepared_bundles<-new.env(parent=emptyenv())
base<-list(customs_value=100,ieepa_ftz_entry=FALSE,s232_vehicle_parts_certification='none',
 s232_auto_parts_use=FALSE,s232_mhd_parts_use=FALSE,
 s232_auto_usmca_eligible=FALSE,s232_mhd_usmca_eligible=FALSE,
 contains_copper=TRUE,s232_copper_only_material=FALSE,copper_value_determination='substantiated',declared_copper_content_value=20)
add<-function(name,facts=base,hts='8544429090',country='2010',at='2026-03-01T12:00:00-05:00',amount=10,
 codes=NULL,missing=NULL,source=NULL,bundle=b,variant=NULL) {
 if(identical(facts$s232_vehicle_parts_certification,'mhd'))facts$claims<-as.list(unique(c(unlist(facts$claims),'SECTION_232_CERTIFIED_MHD_PARTS')))
 if(identical(facts$s232_vehicle_parts_certification,'automobile'))facts$claims<-as.list(unique(c(unlist(facts$claims),'SECTION_232_CERTIFIED_AUTO_PARTS')))
 cache_key<-if(is.null(variant))'main' else variant
 if(!exists(cache_key,envir=prepared_bundles,inherits=FALSE))prepared_bundles[[cache_key]]<-prepare_shipment_bundle(bundle)
 r<-evaluate_shipment_prepared(prepared_bundles[[cache_key]],hts,country,at,facts)
 if(!isTRUE(all.equal(r$known_subtotal,amount))||(!is.null(missing)&&!setequal(r$missing_inputs,missing))) {
  print(list(name=name,result=r[c('known_subtotal','missing_inputs','source_errors')],components=r$components));stop('Vehicle parts source decision regression')
 }
 applied<-Filter(function(c)c$status=='applied',r$components)
 got<-unique(unlist(lapply(applied,`[[`,'reporting_codes')))
 if(!is.null(codes)&&!all(codes%in%got)){print(list(name=name,codes=got));stop('Vehicle parts reporting regression')}
 if(!is.null(source))stopifnot(any(grepl(source,r$source_errors,fixed=TRUE)))
 stopifnot(is.null(r$complete_total))
 cases[[length(cases)+1L]]<<-list(name=name,bundle=variant,hts10=hts,country=country,entry_at=at,facts=facts,expected=shipment_result_for_json(r))
 invisible(r)
}
add('Ordinary copper is unaffected when no optional declaration was made',codes='9903.78.01')
v<-base;v$s232_vehicle_parts_certification<-'mhd';v$s232_mhd_parts_use<-TRUE
add('Certified MHD part pays25 on the article instead of50 on copper',v,amount=25,codes='9903.74.09',missing=character())
v$s232_mhd_usmca_eligible<-TRUE;v$s232_mhd_knockdown_kit_or_compilation<-FALSE
add('USMCA individual MHD part remains subject while payable duty is zero',v,amount=0,codes='9903.74.10',missing=character())
v$s232_mhd_knockdown_kit_or_compilation<-TRUE
add('USMCA MHD knockdown kit remains charged',v,amount=25,codes='9903.74.09')
v<-base;v$s232_vehicle_parts_certification<-'mhd';v$s232_mhd_parts_use<-FALSE
add('A declaration alone cannot turn a non-part into MHD coverage',v)
v<-base;v$s232_vehicle_parts_certification<-NULL
add('Ordinary entry needs no optional certification facts',v,amount=10)
v$claims<-list('SECTION_232_CERTIFIED_MHD_PARTS')
add('Requested certified path needs the actual importer certification',v,amount=0,missing='s232_vehicle_parts_certification')
v<-base;v$s232_vehicle_parts_certification<-'automobile';v$s232_auto_parts_use<-TRUE
add('Certified passenger vehicle part suppresses original copper',v,amount=25,codes='9903.94.07')
w<-v;w$s232_auto_parts_use<-FALSE
r<-add('A non-part cannot acquire an optional automobile reporting exemption',w)
stopifnot(!any(vapply(r$components,function(c)c$status=='applied'&&'9903.94.06'%in%unlist(c$reporting_codes),logical(1))))
add('Certified EU part uses the source General floor',v,country='4279',amount=12.4,codes='9903.94.45')
add('Certified Japanese part uses the source General floor',v,country='5880',amount=12.4,codes='9903.94.55')
add('Certified Korean part uses the source General floor',v,country='5800',amount=12.4,codes='9903.94.65')
v$s232_uk_auto_parts_uk_vehicle_use<-TRUE
add('Certified UK part used in a UK automobile uses the combined10heading',v,country='4120',amount=10,codes='9903.94.33')
v$s232_uk_auto_parts_uk_vehicle_use<-FALSE
add('UK-origin part without UK-vehicle use retains ordinary certified charge',v,country='4120',amount=25,codes='9903.94.07')
v<-base;v$s232_vehicle_parts_certification<-'automobile';v$s232_auto_parts_use<-TRUE
v$s232_auto_usmca_eligible<-TRUE;v$s232_auto_knockdown_kit_or_compilation<-FALSE
add('Certified auto part USMCA relief re-evaluates copper suppression',v,amount=0,codes='9903.94.06')
v$s232_auto_knockdown_kit_or_compilation<-TRUE
add('Certified auto knockdown kit pays statutory25',v,amount=25,codes='9903.94.07')
v<-base;v$s232_vehicle_parts_certification<-'mhd';v$s232_mhd_parts_use<-TRUE
add('Before the optional certified commencement copper remains payable',v,at='2025-11-01T00:00:59-04:00')
add('At the original legal minute the MHD declaration changes the action',v,at='2025-11-01T00:01:00-04:00',amount=25,codes='9903.74.09')
v<-base;v$s232_mhd_parts_use<-TRUE
add('Listed MHD part needs no optional certification election',v,hts='4009120020',amount=25,codes='9903.74.08')
v$s232_mhd_parts_use<-FALSE
add('Listed statistical code with non-part use receives the actual non-part heading',v,hts='4009120020',amount=0,codes='9903.74.11')
v<-base;v$s232_vehicle_parts_certification<-'mhd';v$s232_mhd_parts_use<-TRUE
add('Chapter73 cannot use certified MHD path but listed MHD scope remains',v,hts='7320106015',amount=25,codes='9903.74.08')
v<-base;v$s232_vehicle_parts_certification<-'mhd';v$s232_mhd_parts_use<-TRUE;v$claims<-list('SECTION_232_MHD_IMPORT_OFFSET')
add('An unallocated model credit cannot price an actual importer offset',v,amount=0,source='mhd_parts_approved_offset')
v<-base;v$s232_vehicle_parts_certification<-'mhd';v$s232_mhd_parts_use<-TRUE;v$claims<-list('CHAPTER_98');v$chapter98_properly_claimed<-TRUE;v$chapter98_provision<-'98020060'
# Full-value MHD treatment is settled; copper itself still has a separate pending
# Chapter98 applicability path, which cannot add an unsupported component.
add('Express MHD9802full-value exception does not use processing-only value',v,amount=25,codes='9903.74.09')
v$chapter98_provision<-'98020050'
add('Other Chapter98 treatment is not an invented full-value duty',v,amount=0,source='mhd_parts_chapter98_selected')
# All MHD source boundaries bind actual metal codes. The AST is evaluated in
# both runtimes with a synthetic competing metal action, not a coverage oracle.
late<-seed;late$valid_until<-f$supported_until
for(code in c('9903.78.01','9903.82.17','9903.82.19','9903.82.26','9903.82.03')) {
 metal<-list(contract_version='sail.shipment-rule-fragment/v1',id=paste0('synthetic-',code),sources=f$sources,source_artifacts=f$source_artifacts,
  rules=list(list(id='synthetic-metal',action_id='synthetic-metal',authority='section_232',kind='duty',verification='verified',
   scope=list(hts_exact=list('8544429090')),when=list(value=TRUE),formula=list(value=50),reporting_codes=list(code),source_ids=f$rules[[1]]$source_ids)),coverage=list())
 bb<-compose_shipment_rules(late,list(f,metal));key<-paste0('boundary-',code);bundles[[key]]<-bb
 for(at in c('2026-04-06T00:00:59-04:00','2026-04-06T00:01:00-04:00','2026-04-23T00:00:59-05:00',
  '2026-04-23T00:01:00-05:00','2026-06-08T00:00:59-04:00','2026-06-08T00:01:00-04:00')) {
  v<-base;v$s232_vehicle_parts_certification<-'mhd';v$s232_mhd_parts_use<-TRUE
  add(paste('Original nonstacking boundary',code,at),v,at=at,amount=if(switch(code,'9903.78.01'=.shipment_time(at)<.shipment_time('2026-04-06T00:01:00-04:00'),
   '9903.82.17'=.shipment_time(at)>=.shipment_time('2026-04-06T00:01:00-04:00'),
   '9903.82.19'=.shipment_time(at)>=.shipment_time('2026-04-23T00:01:00-05:00'),
   '9903.82.26'=.shipment_time(at)>=.shipment_time('2026-06-08T00:01:00-04:00'),FALSE))25 else 75,bundle=bb,variant=key)
 }
}
q<-base;q$s232_vehicle_parts_certification<-'mhd';q$s232_mhd_parts_use<-TRUE
q$s232_mhd_usmca_eligible<-TRUE;q$s232_mhd_knockdown_kit_or_compilation<-FALSE
q$s232_usmca_mhd_parts_not_kits<-q$s122_usmca_mhd_parts_not_kits<-q$s338_usmca_mhd_parts_not_kits<-FALSE
add('Legacy contradictory MHD aliases cannot replace the source-owned eligibility decision',q,amount=0,codes='9903.74.10')
q<-base;q$copper_share<-0;q$assembly_credit<-1e9;q$modeled_s232_rate<-1
add('Modeled shares and assembly credits cannot affect vehicle decisions',q)
shuffled<-b;shuffled$rules<-c(rev(b$rules),b$rules[1])
stopifnot(identical(evaluate_shipment_bundle(b,'8544429090','2010','2026-03-01T12:00:00-05:00',base),
 evaluate_shipment_bundle(shuffled,'8544429090','2010','2026-03-01T12:00:00-05:00',base)))
# Actual emergency/surcharge compilers, with an explicitly synthetic no-other-
# Section232 assumption for dependency arithmetic. This is not a release or a
# legal completeness attestation. Non-232 coverage remains unresolved.
source('src/ieepa_fentanyl.R');source('src/section122_revision.R')
controlled<-function(other) {
 seed2<-seed;seed2$valid_from<-max(seed$valid_from,other$supported_from)
 seed2$valid_until<-min(seed$valid_until,other$supported_until)
 bb<-compose_shipment_rules(seed2,list(f,a,copper,other))
 sid<-'synthetic-no-other232-for-vehicle-interactions'
 bb$sources[[length(bb$sources)+1L]]<-list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),
  url='https://example.invalid/vehicle-interaction-fixture',citation='Synthetic no-other232 assumption solely for technical action composition; not production coverage')
 bb$coverage<-list(list(authority='section_232',status='verified',determination='rules',source_ids=list(sid),
  rule_ids=as.list(vapply(Filter(function(r)r$authority=='section_232',bb$rules),`[[`,character(1),'id'))))
 bb
}
e<-compile_ieepa_emergency_fragment(load_ieepa_emergency_source('2025_rev_26'),'8544429090')
bundles$emergency<-controlled(e)
s122<-compile_s122_fragment(load_s122_revision_source('2026_rev_4'),'8544429090')
bundles$surcharge<-controlled(s122)
for(mode in c('none','mhd','mhd_usmca')) {
 v<-base;v$s232_vehicle_parts_certification<-if(mode=='none')'none' else 'mhd'
 v$s232_mhd_parts_use<-mode!='none';v$s232_mhd_usmca_eligible<-mode=='mhd_usmca';v$s232_mhd_knockdown_kit_or_compilation<-FALSE
 v$ieepa_origin_rule_confirmed<-TRUE;v$ieepa_personal_accompanied_baggage<-v$ieepa_qualifying_humanitarian_donation<-v$ieepa_informational_material<-v$ieepa_de_minimis_claimed<-FALSE
 v$ieepa_potash<-v$ieepa_canada_energy_or_critical_mineral<-v$ieepa_canada_cbp_evasion_determination<-FALSE
 r<-add(paste('Original Mexico emergency/MHD relation',mode),v,country='2010',at='2025-11-01T12:00:00-04:00',
  amount=switch(mode,none=35,mhd=25,mhd_usmca=0),bundle=bundles$emergency,variant='emergency')
 v$s122_ftz_entry<-FALSE
 v$s122_personal_baggage<-v$s122_humanitarian_donation<-v$s122_informational_material<-v$s122_chapter98_claimed<-v$s122_gn6_civil_aircraft<-FALSE
 v$s232_usmca_mhd_parts_not_kits<-v$s122_usmca_mhd_parts_not_kits<-mode!='mhd_usmca'
 add(paste('Original Section122/MHD relation',mode),v,country='2010',at='2026-03-01T12:00:00-05:00',
  amount=switch(mode,none=18,mhd=25,mhd_usmca=0),bundle=bundles$surcharge,variant='surcharge')
}
source('src/ieepa_reciprocal_revision.R')
rp<-compile_reciprocal_initial_fragment(load_reciprocal_scope('2025_rev_26'),'8544429090')
bundles$reciprocal<-controlled(rp)
for(mode in c('automobile','mhd'))for(origin in c('4279','5800')) {
 v<-base;v$s232_vehicle_parts_certification<-mode;v$s232_auto_parts_use<-mode=='automobile';v$s232_mhd_parts_use<-mode=='mhd'
 v$ieepa_personal_accompanied_baggage<-v$ieepa_qualifying_humanitarian_donation<-v$ieepa_informational_material<-v$ieepa_de_minimis_claimed<-FALSE
 r<-add(paste('Original reciprocal certified vehicle-part exclusion',mode,origin),v,country=origin,at='2025-11-02T12:00:00-05:00',
  amount=if(mode=='automobile')12.4 else 25,bundle=bundles$reciprocal,variant='reciprocal')
 stopifnot(!any(vapply(r$components,function(c)c$authority=='ieepa_reciprocal'&&c$status=='applied'&&c$amount>0,logical(1))))
}
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/vehicle-parts.json.gz','w')
 writeLines(jsonlite::toJSON(list(bundle=b,extra_bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'vehicle part source, valuation, selection and boundary cases passed\n')
