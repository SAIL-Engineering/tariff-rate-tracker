# Commerce2026-02049 and CBP68559236: approved entry/model value, retroactivity,
# actual import-from condition and mandatory SPI S must compose with base duty.
source('src/helpers.R');source('src/shipment_build.R');source('src/section232_mhd_vehicles.R')
product<-'8704221140';origins<-c('2010','5700')
v<-compile_s232_mhd_vehicles_fragment('2026_rev_4',product,origins)
base<-compile_shipment_base_fragment(load_shipment_base_source('2026_rev_4'),product,origins)
seed<-list(contract_version='sail.shipment-rules/v1',dataset_version='mhd-approved-content-source-test',revision='2026_rev_4',
 evidence_snapshot_id='commerce-and-cbp-mhd-procedures',valid_from=v$supported_from,valid_until=v$supported_until,
 products=list(product),countries=as.list(origins),sources=list(),rules=list(),coverage=list(),
 coverage_requirements=list('base','section_232','section_301','adcvd'),fact_definitions=list(),claim_definitions=list())
hb<-compose_shipment_rules(seed,list(v));historical<-prepare_shipment_bundle(hb)
seed$valid_from<-max(seed$valid_from,base$supported_from);seed$valid_until<-min(seed$valid_until,base$supported_until)
b<-compose_shipment_rules(seed,list(v,base));prepared<-prepare_shipment_bundle(b);cases<-list()
nov_base<-compile_shipment_base_fragment(load_shipment_base_source('2025_rev_26'),product,origins)
nov_seed<-seed;nov_seed$revision<-'2025_rev_26';nov_seed$valid_from<-nov_base$supported_from;nov_seed$valid_until<-nov_base$supported_until
nb<-compose_shipment_rules(nov_seed,list(v,nov_base));november<-prepare_shipment_bundle(nb)
facts<-list(customs_value=100,ieepa_ftz_entry=FALSE,s232_mhd_vehicle=TRUE,s232_mhd_manufacture_year=2020,
 claims=list('SECTION_232_MHD_US_CONTENT'),usmca_origin_eligible=TRUE,usmca_properly_claimed=TRUE,
 s232_mhd_commerce_us_content_approved=TRUE,s232_mhd_cbp_overstatement_applies=FALSE,
 s232_mhd_non_us_content_value=40)
check<-function(label,f=facts,want,at='2026-04-05T12:00:00-04:00',missing=character(),context=prepared,country='2010',variant=NULL) {
 r<-evaluate_shipment_prepared(context,product,country,at,f)
 if(!isTRUE(all.equal(r$known_subtotal,want))||!setequal(missing,r$missing_inputs)) {
  print(list(label=label,result=r[c('known_subtotal','missing_inputs','source_errors')]));stop('MHD content/base claim regression')
 }
 stopifnot(is.null(r$complete_total))
 cases[[length(cases)+1L]]<<-list(name=label,bundle=variant %||% if(identical(context,historical))'historical' else NULL,
  hts10=product,country=country,entry_at=at,facts=f,expected=shipment_result_for_json(r))
 invisible(r)
}
check('MHD content election includes required SPI S instead of adding4MFN',want=10)
check('Inapplicable MHD content cannot imply a base preference before commencement',want=4,at='2025-11-01T00:00:59-04:00',context=november,variant='november')
check('Authorized retroactive model/entry treatment reaches original November1',want=10,at='2025-11-01T00:01:00-04:00',context=november,variant='november')
check('May guidance publication is not the legal liability start',want=10,at='2026-05-07T12:00:00-04:00',context=historical)
q<-facts;q$claims<-list();q$usmca_origin_eligible<-q$usmca_properly_claimed<-q$s232_mhd_commerce_us_content_approved<-NULL
check('No requested preference means full MFN4 plus MHD25 without optional inputs',q,29)
q<-facts;q$claims<-list('USMCA');check('USMCA alone removes base but not full vehicle232',q,25)
q<-facts;q$usmca_properly_claimed<-NULL;check('Missing proper SPI claim is not zero base',q,0,missing='usmca_properly_claimed')
q<-facts;q$usmca_origin_eligible<-NULL;check('Model authorization does not establish GN11 entitlement',q,0,missing='usmca_origin_eligible')
check('A different origin cannot acquire another origin content or implicit preference',want=29,country='5700')
q<-facts;q$s232_mhd_commerce_us_content_approved<-FALSE;check('An approval outside this model/importer/entry cannot grant relief',q,25)
q<-facts;q$s232_mhd_non_us_content_value<-NULL;check('Commerce-authorized non-US amount is required',q,0,missing='s232_mhd_non_us_content_value')
q<-facts;q$s232_mhd_non_us_content_value<-0;check('Zero non-US amount remains source-covered',q,0)
q<-facts;q$s232_mhd_us_content_value<-999;q$usmca_share<-1;q$assembly_credit<-999;check('Caller US estimate/model shares cannot replace authorized non-US amount',q,10)
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/mhd-content.json.gz','w')
 writeLines(jsonlite::toJSON(list(bundle=b,extra_bundles=list(historical=hb,november=nb),cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'MHD content, approval, retroactivity, origin and base-claim calculations passed\n')
