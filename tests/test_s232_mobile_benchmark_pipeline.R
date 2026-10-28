suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/04_parse_products.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
# Actual native classification and inherited General expression, not a patched
# rate row. All ordinary quantities/source ownership remain in the normal path.
path<-'data/hts_archives/hts_2026_rev_19.json';raw<-jsonlite::fromJSON(path,simplifyVector=FALSE)
chapter<-'';kept<-list()
for(row in raw) {
 if(nzchar(row$htsno %||% ''))chapter<-substr(row$htsno,1,2)
 if(chapter=='84')kept[[length(kept)+1L]]<-row
}
tmp<-tempfile(fileext='.json');jsonlite::write_json(kept,tmp,auto_unbox=TRUE,null='null')
products<-parse_products(tmp) %>% filter(hts10=='8427104090');unlink(tmp);stopifnot(nrow(products)==1L)
ch99<-parse_chapter99(path,revision_id='2026_rev_19')
export<-Sys.getenv('MOBILE_BENCHMARK_PIPELINE_EXPORT','');out<-if(nzchar(export))export else tempfile('native-mobile-')
if(file.exists(out))stop('Use a new fixture directory')
dir.create(out,recursive=TRUE);save_ledger<-duty_ledger_save
duty_ledger_save<-function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates<-calculate_rates_for_revision(products,ch99,NULL,NULL,'5700','2026_rev_19',as.Date('2026-09-15'),
 policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-09-16'))
stopifnot(all(is.na(rates$statutory_total_rate)))
q<-list(customs_value=100,ieepa_ftz_entry=FALSE,steel_weight_fraction=.5,us_steel_origin_fraction=.85,motorcycle_part_for_us_manufacture=FALSE)
cases<-list();at<-'2026-09-15T12:00:00-04:00'
check<-function(name,facts=q,metal=10,missing=character()) {
 r<-resolve_shipment_duties(file.path(out,'2026_rev_19'),'8427104090','5700',at,facts)
 components<-Filter(function(c)c$authority=='section_232'&&c$status=='applied',r$components)
 stopifnot(sum(vapply(components,`[[`,numeric(1),'amount'))==metal,
  !'column1_duty_amount'%in%r$missing_inputs,all(missing%in%r$missing_inputs),is.null(r$complete_total))
 fl<-Filter(function(c)startsWith(c$action_id,'s301_forced_labor_')&&c$status=='applied',r$components)
 if(!is.null(facts$ieepa_ftz_entry)&&!facts$ieepa_ftz_entry)stopifnot(length(fl)==1L,fl[[1]]$amount==0)
 cases[[length(cases)+1L]]<<-list(hts10='8427104090',country='5700',entry_at=at,facts=facts,expected=shipment_result_for_json(r),case_name=name)
}
check('Native Free supplies the benchmark without a caller amount')
f<-q;f$column1_duty_amount<-999;f$modeled_assembly_credit<-9999
check('Caller/model values cannot override the primary source benchmark',f)
f<-q;f$us_steel_origin_fraction<-0
check('Nonqualifying material selects its source-backed alternative',f,metal=25)
f<-q;f$customs_value<-NULL
check('Actual shipment value remains necessary, known applicability still removes forced labor',f,metal=0,missing='customs_value')
f<-q;f$ieepa_ftz_entry<-NULL
check('Unknown admission context cannot borrow ordinary pricing',f,metal=0,missing='ieepa_ftz_entry')
f$ieepa_ftz_entry<-TRUE
check('FTZ rate/classification history remains a precise separate question',f,metal=0)
if(nzchar(export)) {
 arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
 # The HTTP contract accepts shipment fields; case names are local annotations.
 cases<-lapply(cases,function(c){c$case_name<-NULL;c})
 jsonlite::write_json(list(revision_dir='2026_rev_19',cases=cases),file.path(out,'delivery_cases.json'),auto_unbox=TRUE,null='null',digits=17)
} else unlink(out,recursive=TRUE)
cat(length(cases),'native mobile benchmark/metal/forced-labor/FTZ normal-build cases passed\n')
