suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/04_parse_products.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R');source('scripts/lib/shipment_partition_validation.R')
# Seven product/origin cells in three source frames, through the ordinary emitter.
# This is a point diagnostic; no full revision or timeseries is rebuilt.
export<-Sys.getenv('COPPER_PIPELINE_EXPORT','');parent<-if(nzchar(export))export else tempfile('copper-normal-')
stopifnot(!file.exists(parent));dir.create(parent,recursive=TRUE)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
save_ledger<-duty_ledger_save
duty_ledger_save<-function(...)save_ledger(dir=file.path(parent,'provenance'),...)
specs<-list(list(revision='2025_rev_17',date='2025-08-02',products=c('7408113000','8544429090'),countries=c('4279','5700')),
 list(revision='2026_rev_4',date='2026-04-05',products=c('7408113000','8544429090'),countries='4279'),
 list(revision='2026_rev_5',date='2026-04-06',products='7408113000',countries='4279'))
selected<-Sys.getenv('COPPER_PIPELINE_REVISIONS','')
if(nzchar(selected))specs<-Filter(function(s)s$revision%in%strsplit(selected,',',fixed=TRUE)[[1]],specs)
stopifnot(length(specs)>0)
for(s in specs) {
 out<-file.path(parent,s$revision);dir.create(out)
 path<-paste0('data/hts_archives/hts_',s$revision,'.json');raw<-jsonlite::fromJSON(path,simplifyVector=FALSE)
 chapter<-'';kept<-list()
 for(row in raw){if(nzchar(row$htsno %||% ''))chapter<-substr(row$htsno,1,2);if(chapter%in%c('74','85'))kept[[length(kept)+1L]]<-row}
 subset<-tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
 products<-parse_products(subset)%>%filter(hts10%in%s$products);unlink(subset);stopifnot(nrow(products)==length(s$products))
 ch99<-parse_chapter99(path,revision_id=s$revision)
 rates<-calculate_rates_for_revision(products,ch99,NULL,NULL,s$countries,s$revision,as.Date(s$date),
  policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date(s$date))
 arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
 dir<-file.path(out,s$revision)
 validation<-validate_shipment_partition(dir,file.path(out,'rates_fixture.parquet'))
 stopifnot(validation$grid_cells==length(s$products)*length(s$countries),!validation$legal_coverage_complete,
  file.exists(file.path(dir,'section232_copper_rules.json')))
 facts<-list(customs_value=100,ieepa_ftz_entry=FALSE,s232_vehicle_parts_certification='none',contains_copper=TRUE,s232_copper_only_material=FALSE,
  copper_value_determination='substantiated',declared_copper_content_value=20,copper_content_value=99,
  copper_weight_fraction=1,us_copper_origin_fraction=0,
  ieepa_personal_accompanied_baggage=FALSE,ieepa_qualifying_humanitarian_donation=FALSE,
  ieepa_informational_material=FALSE,ieepa_de_minimis_claimed=FALSE,
  reciprocal_partner_civil_aircraft_gn6_excluding_unmanned=FALSE,s301_labor_civil_aircraft_gn6=FALSE)
 cases<-list()
 times<-if(s$revision=='2025_rev_17')'2025-08-02T12:00:00-04:00' else if(s$revision=='2026_rev_4')'2026-04-05T12:00:00-04:00' else
  c('2026-04-06T00:00:59-04:00','2026-04-06T00:01:00-04:00')
 for(at in times)for(hts in s$products) {
  r<-resolve_shipment_duties(dir,hts,'4279',at,facts)
  amount<-function(authority)sum(vapply(Filter(function(c)c$authority==authority&&c$status=='applied',r$components),`[[`,numeric(1),'amount'))
  expected<-if(grepl('00:01:00',at))50 else 10
  if(amount('section_232')!=expected) {print(r[c('known_subtotal','missing_inputs','source_errors')]);stop('Normal copper/April replacement amount failed')}
  if(s$revision=='2025_rev_17')stopifnot(amount('ieepa_reciprocal')==0,
   'coverage_dependency_unverified:section_232'%in%r$source_errors)
  stopifnot(is.null(r$complete_total))
  cases[[length(cases)+1L]]<-list(hts10=hts,country='4279',entry_at=at,facts=facts,expected=shipment_result_for_json(r))
 }
 # Removing raw content is not equivalent to CBP's declared inability to value it.
 q<-facts;q$declared_copper_content_value<-NULL
 r<-resolve_shipment_duties(dir,s$products[1],'4279',times[1],q)
 stopifnot('declared_copper_content_value'%in%r$missing_inputs,is.null(r$complete_total))
 cases[[length(cases)+1L]]<-list(hts10=s$products[1],country='4279',entry_at=times[1],facts=q,expected=shipment_result_for_json(r))
 if(s$revision=='2026_rev_4'&&'8544429090'%in%s$products)for(mode in c('mhd','automobile','mhd_usmca')) {
  v<-facts;v$s232_vehicle_parts_certification<-if(mode=='automobile')'automobile' else 'mhd'
  v$claims<-list(if(mode=='automobile')'SECTION_232_CERTIFIED_AUTO_PARTS' else 'SECTION_232_CERTIFIED_MHD_PARTS')
  v$s232_auto_parts_use<-mode=='automobile';v$s232_mhd_parts_use<-mode!='automobile'
  v$s232_auto_usmca_eligible<-FALSE;v$s232_mhd_usmca_eligible<-mode=='mhd_usmca';v$s232_mhd_knockdown_kit_or_compilation<-FALSE
  # Deliberately contradict the old aliases. The emitted peer-action decisions
  # must own the claim interaction in Section122 and338 as well.
  v$s232_usmca_mhd_parts_not_kits<-v$s122_usmca_mhd_parts_not_kits<-v$s338_usmca_mhd_parts_not_kits<-mode!='mhd_usmca'
  r<-resolve_shipment_duties(dir,'8544429090','4279',times[1],v)
  expected<-switch(mode,mhd=25,automobile=12.4,mhd_usmca=0)
  got<-sum(vapply(Filter(function(c)c$authority=='section_232'&&c$status=='applied',r$components),`[[`,numeric(1),'amount'))
  stopifnot(isTRUE(all.equal(got,expected)),is.null(r$complete_total))
  cases[[length(cases)+1L]]<-list(hts10='8544429090',country='4279',entry_at=times[1],facts=v,expected=shipment_result_for_json(r))
 }
 jsonlite::write_json(list(revision_dir=s$revision,cases=cases),file.path(out,'delivery_cases.json'),auto_unbox=TRUE,null='null',digits=17)
}
if(!nzchar(export))unlink(parent,recursive=TRUE)
cat(sum(vapply(specs,function(s)length(s$products)*length(s$countries),integer(1))),
 'normal Parquet cells: copper amount, incomplete cross-program coverage guards and April replacement boundaries passed; complete totals remain unverified\n')
