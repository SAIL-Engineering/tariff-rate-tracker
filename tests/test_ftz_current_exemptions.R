source('src/helpers.R');source('src/section122_revision.R');source('src/section338_revision.R');source('src/compile_shipment_rules.R')
cases<-list();bundles<-list()
specs<-list(list(id='s122',revision='2026_rev_4',hts='8505110070',country='5700',at='2026-03-01T12:00:00-05:00',
 f=compile_s122_fragment(load_s122_revision_source('2026_rev_4'),'8505110070'),facts=list(s122_ftz_entry=TRUE)),
 list(id='s338',revision='2026_rev_17',hts='9403200090',country='1220',at='2026-09-01T12:00:00-04:00',
 f=compile_s338_fragment('2026_rev_17','9403200090'),facts=list(s338_ftz_entry=TRUE,s338_personal_baggage=FALSE,s338_civil_aircraft_gn6=TRUE)))
for(s in specs) {
 b<-list(contract_version='sail.shipment-rules/v1',dataset_version='ftz-current-exemption-test-not-production',revision=s$revision,
  evidence_snapshot_id='primary-source-test',valid_from=sub('T[0-9:]+','T00:00:00',s$at),valid_until=sub('T[0-9:]+','T23:59:59',s$at),
  products=list(s$hts),countries=list(s$country),sources=list(),rules=list(),coverage=list(),fact_definitions=list(),claim_definitions=list(),
  coverage_requirements=list(if(s$id=='s122')'section_122' else 'section_338'))
 b<-compose_shipment_rules(b,list(s$f));r<-evaluate_shipment_bundle(b,s$hts,s$country,s$at,s$facts)
 stopifnot(r$status=='unresolved_source',is.null(r$complete_total),r$known_subtotal==0,
  !length(Filter(function(c)c$status=='applied',r$components)),any(grepl('ftz_admission',r$source_errors,fixed=TRUE)))
 bundles[[s$id]]<-b;cases[[length(cases)+1L]]<-list(name=paste(s$id,'current product exemption cannot settle an FTZ admission history'),
  bundle=s$id,hts10=s$hts,country=s$country,entry_at=s$at,facts=s$facts,expected=shipment_result_for_json(r))
}
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/ftz-current-exemptions.json.gz','w');writeLines(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat('Section122/338 FTZ history precedes a current product exemption; no current-date zero is assumed\n')
