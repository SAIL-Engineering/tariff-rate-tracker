# Original proclamation/annex calculations, not expectations derived from rates.
source('src/helpers.R');source('src/compile_shipment_rules.R');source('src/section232_mhd_vehicles.R')
source('src/section232_mhd_parts.R');source('src/section232_autos.R')
products<-c('8705900080','8705900020','8702103100','8706000300','8704600000')
origins<-c('2010','1220','5700','2390')
cat('MHD conformance: compiling original vehicles/buses and overlapping parts\n')
v<-compile_s232_mhd_vehicles_fragment('2026_rev_4',products,origins)
p<-compile_s232_mhd_parts_fragment('2026_rev_4',products)
a<-compile_s232_autos_fragment('2026_rev_4',products,origins,native_interactions=FALSE)
seed<-list(contract_version='sail.shipment-rules/v1',dataset_version='mhd-vehicle-original-source-not-release',revision='2026_rev_4',
 evidence_snapshot_id='original-vehicle-annexes',valid_from=v$supported_from,valid_until=v$supported_until,
 products=as.list(products),countries=as.list(origins),sources=list(),rules=list(),coverage=list(),
 coverage_requirements=list('base','section_232','section_301','ieepa_reciprocal','adcvd'),fact_definitions=list(),claim_definitions=list())
b<-compose_shipment_rules(seed,list(v,p,a));cases<-list();bundles<-list();cache<-new.env(parent=emptyenv())
base<-list(customs_value=100,ieepa_ftz_entry=FALSE,s232_vehicle_parts_certification='none',s232_mhd_vehicle=TRUE,
 s232_mhd_manufacture_year=2020,s232_mhd_parts_use=FALSE,s232_auto_parts_use=FALSE,s232_auto_passenger_vehicle=FALSE,
 s232_mhd_usmca_eligible=FALSE,s232_auto_usmca_eligible=FALSE,usmca_origin_eligible=FALSE,usmca_properly_claimed=TRUE)
add<-function(name,facts=base,hts='8705900080',country='2010',at='2026-03-01T12:00:00-05:00',amount=25,
 codes='9903.74.01',missing=character(),error=NULL,bundle=b,variant=NULL) {
 if(!length(facts))facts<-structure(list(),names=character())
 key<-variant %||% 'main';if(!exists(key,cache,inherits=FALSE))cache[[key]]<-prepare_shipment_bundle(bundle)
 r<-evaluate_shipment_prepared(cache[[key]],hts,country,at,facts)
 applied<-Filter(function(c)c$status=='applied',r$components)
 got<-sort(unique(unlist(lapply(applied,`[[`,'reporting_codes'))))
 if(!isTRUE(all.equal(r$known_subtotal,amount))||!setequal(r$missing_inputs,missing)||!setequal(got,codes)||
   (!is.null(error)&&!any(grepl(error,r$source_errors,fixed=TRUE)))) {
  print(list(name=name,result=r[c('known_subtotal','missing_inputs','source_errors')],codes=got));stop('MHD vehicle decision regression')
 }
 stopifnot(is.null(r$complete_total))
 cases[[length(cases)+1L]]<<-list(name=name,bundle=variant,hts10=hts,country=country,entry_at=at,facts=facts,expected=shipment_result_for_json(r))
 invisible(r)
}
for(coo in origins)add(paste('Ordinary vehicle statutory25 all origins',coo),country=coo)
add('No vehicle duty before original legal minute',at='2025-11-01T00:00:59-04:00',facts=list(),amount=0,codes=character())
add('Original vehicle commencement minute',at='2025-11-01T00:01:00-04:00')
q<-base;q$s232_mhd_vehicle<-FALSE;q$s232_mhd_manufacture_year<-NULL
add('Listed statistical provision does not establish medium/heavy identity',q,amount=0,codes='9903.74.05')
q<-base;q$s232_mhd_vehicle<-NULL
add('Missing actual vehicle identity is not zero duty',q,amount=0,codes=character(),missing='s232_mhd_vehicle')
q<-base;q$s232_mhd_manufacture_year<-NULL
add('Missing manufacture year does not deny the age exception',q,amount=0,codes=character(),missing='s232_mhd_manufacture_year')
q<-base;q$s232_mhd_manufacture_year<-2000
add('Twenty-five manufacture calendar years exempt the vehicle',q,amount=0,codes='9903.74.07')
q$s232_mhd_manufacture_year<-2001;q$s232_mhd_entry_calendar_year<-2025
add('Manufacture2001 still charged in entry2025',q,at='2025-12-31T23:59:59-05:00')
q$s232_mhd_entry_calendar_year<-2026
add('Manufacture2001 exempt in entry2026',q,at='2026-01-01T00:00:00-05:00',amount=0,codes='9903.74.07')
q$s232_mhd_entry_calendar_year<-2025
add('Pacific entry record controls year over Eastern legal-clock instant',q,at='2025-12-31T21:30:00-08:00')
q$s232_mhd_entry_calendar_year<-NULL
add('Ambiguous NewYear needs actual entry-record year',q,at='2026-01-01T00:00:00-05:00',amount=0,codes=character(),missing='s232_mhd_entry_calendar_year')
q<-base;q$s232_mhd_manufacture_year<-2026
add('Manufacture after entry year is contradictory',q,at='2025-11-02T12:00:00-05:00',amount=0,codes=character(),error='invalid_fact_s232_mhd_manufacture_year_after_entry_year')
q<-base;q$s232_mhd_manufacture_year<-2000.5
add('Fractional manufacture year is rejected',q,amount=0,codes=character(),missing='s232_mhd_manufacture_year')
q<-base;q$usmca_origin_eligible<-TRUE;q$claims<-list('USMCA')
add('USMCA alone does not exempt a whole vehicle',q)
q$claims<-list('SECTION_232_MHD_US_CONTENT');q$s232_mhd_commerce_us_content_approved<-TRUE
q$s232_mhd_non_us_content_value<-40;q$s232_mhd_cbp_overstatement_applies<-FALSE
add('Approved actual US60 leaves non-US40 times25percent',q,amount=10,codes=c('9903.74.03','9903.74.06'))
q$s232_mhd_non_us_content_value<-0
add('All approved US content retains covered-action status',q,amount=0,codes=c('9903.74.03','9903.74.06'))
q$s232_mhd_non_us_content_value<-101
add('Approved content cannot exceed full value',q,amount=0,codes=character(),missing=c('customs_value','s232_mhd_non_us_content_value'))
q$s232_mhd_non_us_content_value<-40;q$s232_mhd_cbp_overstatement_applies<-TRUE
add('Applicable CBP clause6 determination charges full value',q)
q$s232_mhd_cbp_overstatement_applies<-NULL
add('Missing entry/model overstatement determination cannot be assumed absent',q,amount=0,codes=character(),missing='s232_mhd_cbp_overstatement_applies')
q$s232_mhd_commerce_us_content_approved<-FALSE
add('Expressly unapproved content leaves the ordinary statutory charge',q)
q$s232_mhd_commerce_us_content_approved<-NULL
add('Missing approval remains a relevant input',q,amount=0,codes=character(),missing='s232_mhd_commerce_us_content_approved')
q$s232_mhd_commerce_us_content_approved<-TRUE;q$s232_mhd_cbp_overstatement_applies<-FALSE
add('Column2 No change cannot grant Column1 content relief',q,country='2390')
q<-base;q$s232_mhd_vehicle<-NULL;q$usmca_origin_eligible<-TRUE
q$claims<-list('SECTION_232_MHD_US_CONTENT')
add('Listed bus is10 and does not acquire vehicle-only content relief',q,hts='8702103100',amount=10,codes='9903.74.02')
q$s232_mhd_manufacture_year<-2000
add('Original proclamation also exempts vintage buses',q,hts='8702103100',amount=0,codes='9903.74.07')
q<-base;q$s232_mhd_vehicle<-NULL;q$s232_mhd_manufacture_year<-NULL
add('Adjacent uncovered statistical suffix is not broadened to HTS8',q,hts='8705900020',amount=0,codes=character())
q<-base;q$s232_auto_parts_use<-TRUE;q$s232_mhd_parts_use<-TRUE
add('Whole chassis vehicle cannot also be an auto or MHD part',q,hts='8706000300')
q$s232_mhd_vehicle<-FALSE;q$s232_auto_parts_use<-FALSE
add('The same chassis treated as an MHD part follows the parts action',q,hts='8706000300',codes=c('9903.74.05','9903.74.08','9903.94.06'))
q<-base;q$s232_auto_passenger_vehicle<-TRUE;q$s232_auto_manufacture_year<-2020
add('Conflicting light and medium-heavy identities cannot yield two vehicle duties',q,hts='8704600000',amount=0,codes=character(),missing=c('s232_auto_passenger_vehicle','s232_mhd_vehicle'))
q<-base;q$s232_auto_manufacture_year<-2020
add('Shared electric-truck scope has only actual MHD25 liability',q,hts='8704600000',codes=c('9903.74.01','9903.94.02'))
q$s232_mhd_vehicle<-FALSE;q$s232_auto_passenger_vehicle<-TRUE
add('Shared electric-truck scope has only actual light-truck25 liability',q,hts='8704600000',codes=c('9903.74.05','9903.94.01'))
q$s232_mhd_vehicle<-NULL
add('Later MHD conditions cannot alter the earlier light-truck action',q,hts='8704600000',at='2025-10-01T12:00:00-04:00',codes='9903.94.01')
q<-base;q$s232_auto_parts_use<-TRUE
add('Later whole-MHD precedence cannot suppress an earlier auto-part action',q,hts='8706000300',at='2025-10-01T12:00:00-04:00',codes='9903.94.05')
q<-base;q$claims<-list('CHAPTER_98');q$chapter98_properly_claimed<-TRUE;q$chapter98_provision<-'98020060'
add('Express9802.00.60 full-value exception',q)
q$chapter98_provision<-'98020050'
add('Uncompiled Chapter98 basis cannot become an assumed full-value charge',q,amount=0,codes=character(),error='mhd_vehicle_chapter98_selected')
q<-base;q$ieepa_ftz_entry<-TRUE
add('Privileged FTZ history does not use an ordinary-entry price',q,amount=0,codes=character(),error='mhd_vehicle_ftz_admission_status')
q<-base;q$assembly_credit<-1e9;q$usmca_share<-1;q$metal_share<-0
add('Model allocations cannot alter a statutory vehicle duty',q)
# Original Section122 note2(aa)(v) expressly names both the non-US (.74.03)
# and US (.74.06) MHD portions. This differs from the qualified auto-content
# exemption. A positive-rate test cannot establish either treatment.
source('src/section122_revision.R');source('src/ieepa_fentanyl.R');source('src/ieepa_reciprocal_revision.R')
controlled<-function(other) {
 seed2<-seed;seed2$valid_from<-max(seed$valid_from,other$supported_from);seed2$valid_until<-min(seed$valid_until,other$supported_until)
 bb<-compose_shipment_rules(seed2,list(v,p,a,other))
 sid<-'synthetic-no-other232-for-mhd-composition'
 bb$sources[[length(bb$sources)+1L]]<-list(id=sid,status='verified',sha256=paste(rep('0',64),collapse=''),
  url='https://example.invalid/mhd-technical-composition',citation='Synthetic no-other232 assumption solely for interpreter composition, never production coverage')
 bb$coverage<-list(list(authority='section_232',status='verified',determination='rules',source_ids=list(sid),
  rule_ids=as.list(vapply(Filter(function(r)r$authority=='section_232',bb$rules),`[[`,character(1),'id'))))
 bb
}
cat('MHD conformance: checking original Section122 content and reporting interaction\n')
s122<-compile_s122_fragment(load_s122_revision_source('2026_rev_4'),products)
bundles$surcharge<-controlled(s122)
q<-base;q$s122_ftz_entry<-FALSE;q$s122_personal_baggage<-q$s122_humanitarian_donation<-q$s122_informational_material<-FALSE
q$s122_chapter98_claimed<-q$s122_gn6_civil_aircraft<-FALSE
add('Section122 ordinary MHD exclusion follows original reporting roles',q,codes=c('9903.74.01','9903.03.06'),bundle=bundles$surcharge,variant='surcharge')
q$claims<-list('SECTION_232_MHD_US_CONTENT');q$usmca_origin_eligible<-TRUE;q$s232_mhd_commerce_us_content_approved<-TRUE
q$s232_mhd_cbp_overstatement_applies<-FALSE;q$s232_mhd_non_us_content_value<-40;q$s122_usmca_entered_free<-TRUE
add('Section122 names both actual approved MHD content portions',q,amount=10,codes=c('9903.74.03','9903.74.06','9903.03.08'),bundle=bundles$surcharge,variant='surcharge')
q$s232_mhd_non_us_content_value<-0
add('Zero-payable approved MHD content remains Section122 exempt',q,amount=0,codes=c('9903.74.03','9903.74.06','9903.03.08'),bundle=bundles$surcharge,variant='surcharge')
q<-base;q$s122_ftz_entry<-FALSE;q$s122_personal_baggage<-q$s122_humanitarian_donation<-q$s122_informational_material<-FALSE
q$s122_chapter98_claimed<-q$s122_gn6_civil_aircraft<-FALSE
add('Section122 listed bus exclusion does not depend on metal rate50',q,hts='8702103100',amount=10,codes=c('9903.74.02','9903.03.06'),bundle=bundles$surcharge,variant='surcharge')
cat('MHD conformance: checking drug-emergency stacking and vintage exception\n')
emergency<-compile_ieepa_emergency_fragment(load_ieepa_emergency_source('2025_rev_26'),products)
bundles$emergency<-controlled(emergency)
q<-base;q$ieepa_origin_rule_confirmed<-TRUE
q$ieepa_personal_accompanied_baggage<-q$ieepa_qualifying_humanitarian_donation<-q$ieepa_informational_material<-q$ieepa_de_minimis_claimed<-FALSE
q$ieepa_potash<-q$ieepa_canada_energy_or_critical_mineral<-q$ieepa_canada_cbp_evasion_determination<-FALSE
add('Modern MHD suppresses Mexico drug-emergency action from Nov1',q,at='2025-11-02T12:00:00-05:00',bundle=bundles$emergency,variant='emergency')
q$s232_mhd_manufacture_year<-2000
add('Vintage exception does not suppress Mexico drug-emergency duty',q,at='2025-11-02T12:00:00-05:00',amount=25,codes=c('9903.74.07','9903.01.01'),bundle=bundles$emergency,variant='emergency')
cat('MHD conformance: checking original reciprocal exemption and independent China301\n')
rp<-compile_reciprocal_initial_fragment(load_reciprocal_scope('2025_rev_26'),products)
bundles$reciprocal<-controlled(rp)
q<-base;q$ieepa_personal_accompanied_baggage<-q$ieepa_qualifying_humanitarian_donation<-q$ieepa_informational_material<-q$ieepa_de_minimis_claimed<-FALSE
q$reciprocal_cbp_transshipment_evasion_determination<-FALSE
add('Original reciprocal MHD exemption follows applicability',q,country='5700',at='2025-11-02T12:00:00-05:00',codes=c('9903.74.01','9903.01.33'),bundle=bundles$reciprocal,variant='reciprocal')
# The independent China Section301 action survives the MHD action and its
# approved-content/vintage paths. Note20(d)/9903.88.02 is25percent on8705.90.00.
source('src/section301_revision.R')
s301<-compile_s301_revision_fragment(load_s301_revision_source('2026_rev_4'),products)
bundles$china301<-compose_shipment_rules(seed,list(v,p,a,s301))
add('Original China301 charge remains cumulative with MHD',country='5700',amount=50,codes=c('9903.74.01','9903.88.02'),bundle=bundles$china301,variant='china301')
q<-base;q$claims<-list('SECTION_232_MHD_US_CONTENT');q$usmca_origin_eligible<-TRUE;q$s232_mhd_commerce_us_content_approved<-TRUE
q$s232_mhd_cbp_overstatement_applies<-FALSE;q$s232_mhd_non_us_content_value<-40
add('Origin restriction prevents a China MHD content discount while301 remains additive',q,country='5700',amount=50,codes=c('9903.74.01','9903.88.02'),bundle=bundles$china301,variant='china301')
q<-base;q$s232_mhd_manufacture_year<-2000
add('MHD vintage exemption does not remove separate China301',q,country='5700',amount=25,codes=c('9903.74.07','9903.88.02'),bundle=bundles$china301,variant='china301')
if('--emit'%in%commandArgs(TRUE)) {
 out<-gzfile('tests/fixtures/shipment/mhd-vehicles.json.gz','w')
 writeLines(jsonlite::toJSON(list(bundle=b,extra_bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=17),out);close(out)
}
cat(length(cases),'MHD vehicle, bus, content and whole-versus-part cases passed\n')
