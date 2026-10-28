suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/section232_revision.R');source('src/shipment_build.R')
revision<-'2026_rev_19';products<-c('8415908010','8211912000')
x<-load_s232_note16_source(revision);f<-compile_s232_note16_fragment(x,products)
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$revision<-revision;b$dataset_version<-'native-column1-benchmarks-not-production';b$products<-as.list(products);b$countries<-list('5700')
b$rules<-b$coverage<-b$claim_definitions<-list();b$fact_definitions<-list();b$coverage_requirements<-list('base','section_232','adcvd')
b$valid_from<-f$supported_from;b$valid_until<-f$supported_until
base<-compile_shipment_base_fragment(load_shipment_base_source(revision),products,'5700')
b<-compose_shipment_rules(b,list(base,f));prepared<-prepare_shipment_bundle(b);cases<-list()
q<-list(customs_value=100,ieepa_ftz_entry=FALSE,aluminum_weight_fraction=.1,steel_weight_fraction=.1,
 aluminum_primary_smelted_or_cast_russia=FALSE,us_aluminum_origin_fraction=.85,us_steel_origin_fraction=.85)
check<-function(name,hts='8415908010',facts=q,metal=8.6,subtotal=10,missing=character()) {
 r<-evaluate_shipment_prepared(prepared,hts,'5700','2026-09-15T12:00:00-04:00',facts)
 applied<-Filter(function(c)c$authority=='section_232'&&c$status=='applied',r$components)
 actual<-sum(vapply(applied,`[[`,numeric(1),'amount'))
 if(abs(actual-metal)>1e-9||abs(r$known_subtotal-subtotal)>1e-9||!setequal(r$missing_inputs,missing)) {
  print(list(case=name,metal=actual,known_subtotal=r$known_subtotal,missing=r$missing_inputs));stop('Native benchmark was not derived from its complete duty expression')
 }
 stopifnot(is.null(r$complete_total))
 cases[[length(cases)+1L]]<<-list(name=name,hts10=hts,country='5700',entry_at='2026-09-15T12:00:00-04:00',facts=facts,expected=shipment_result_for_json(r))
}
check('Published 1.4 percent benchmark supplies the ten percent combined floor')
q$column1_duty_amount<-99;q$modeled_metal_share<-.01;q$assembly_credit<-99999
check('Importer/model benchmark cannot replace the source rate')
q$us_steel_origin_fraction<-0
check('Fifteen percent floor uses the same actual 1.4 percent benchmark',metal=13.6,subtotal=15)
k<-list(customs_value=100,ieepa_ftz_entry=FALSE,steel_weight_fraction=1,us_steel_origin_fraction=0,quantity_each=10)
check('Specific plus ad valorem base is priced once alongside flat metal duty','8211912000',k,metal=25,subtotal=31.44)
k$quantity_each<-NULL
check('Missing legal quantity cannot become a zero base or affect a flat metal amount','8211912000',k,metal=25,subtotal=25,missing='quantity_each')
u<-q;u$claims<-list('USMCA');u$usmca_origin_eligible<-TRUE;u$usmca_properly_claimed<-TRUE;u$us_steel_origin_fraction<-.85
check('Verified preferential-origin facts use the published S rate independently of nonpreferential origin',facts=u,metal=10,subtotal=10)
u$usmca_origin_eligible<-NULL
check('A requested preference alone cannot establish its entitlement',facts=u,metal=0,subtotal=0,missing='usmca_origin_eligible')
k$claims<-list('USMCA');k$usmca_origin_eligible<-TRUE;k$usmca_properly_claimed<-TRUE
check('The published S Free expression does not request a General-only quantity','8211912000',k,metal=25,subtotal=25)
p<-parse_shipment_special_column('Free (S,AU) See 9921.01.01, 9921.01.02 (JP)')
stopifnot(p$status=='parsed',length(p$groups)==2L,p$groups[[1]]$parsed$status=='parsed',p$groups[[2]]$parsed$status=='unresolved_source')
for(s in c('Free (S) ignored condition','Free (S) 2% (S)','Free ((S))'))stopifnot(parse_shipment_special_column(s)$status=='unresolved_source')
ref<-shipment_usmca_reference(list(expression='Free (AU) See 9823.01.01-9823.01.07 (S+)',source_code='04012010',source_row_index=1L))
stopifnot(ref$status=='unresolved_source',!identical(ref$formula,list(value=0)))
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/note16-column1-benchmarks.json.gz','w');writeLines(jsonlite::toJSON(list(bundle=b,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'source-owned nonzero and compound benchmark cases passed\n')
