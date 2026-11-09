# Regression: 2026_rev_16 (2026-08-14) spans §338's 2026-08-22 commencement,
# which rev_17 only publishes on 2026-08-24. One legal state therefore precedes
# commencement and one does not. The per-action columns were created only on the
# in-force branch, so the two states disagreed on nine columns and the revision
# could not be assembled at all (check_legal_state_schema). Before commencement
# the duty is zero, not unknown.
suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
source('src/compile_shipment_rules.R');source('src/section338_revision.R')

products<-readRDS('data/processed/products_2026_rev_4.rds') %>%
 filter(hts10 %in% c('2203000030','0402101000','8537109120','8537109130'))
stopifnot(nrow(products)==4)
ch99<-parse_chapter99('data/hts_archives/hts_2026_rev_16.json',revision_id='2026_rev_16')
pp<-load_policy_params()
# The split instant is the config's, not a literal copied into the test.
stopifnot(as.character(pp$SECTION_338$effective_date)=='2026-08-22')

# The revision-wide action set, derived exactly as calculate_revision_legal_states()
# derives it. Amendments only insert and delete products within an existing
# program, so the set is fixed by the original annex.
actions<-sort(unique(vapply(load_s338_source()$actions,`[[`,character(1),'program')))
stopifnot(identical(actions,c('alcohol','dairy','motor_vehicles')))

out<-tempfile('s338-parity-');dir.create(out)
save_ledger<-duty_ledger_save
duty_ledger_save<-function(...) save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
run<-function(day,until) {
  d<-file.path(out,day);dir.create(d,showWarnings=FALSE)
  calculate_rates_for_revision(products,ch99,NULL,NULL,'1220','2026_rev_16',as.Date(day),
    policy_params=pp,s338_actions=actions,
    normalized_output_dir=d,normalized_valid_until=as.Date(until))
}
before<-run('2026-08-14','2026-08-21')   # state 1: §338 not yet commenced
after <-run('2026-08-22','2026-08-23')   # state 2: §338 in force

# The assembly contract: identical names, in identical order, with identical types.
stopifnot(identical(names(before),names(after)))
for(col in names(before))
  stopifnot(identical(class(before[[col]]),class(after[[col]])))

# All nine columns the failure named are present on BOTH states. The
# modeled_legacy_* names are not written by the zero-fill -- they are derived by
# the shipment projection renaming statutory_*, which is why the fill must run
# before it. This asserts that derivation actually happens.
nine<-c(outer(c('statutory_rate_s338_','modeled_rate_s338_',
                'modeled_legacy_statutory_rate_s338_'),actions,paste0))
stopifnot(length(nine)==9L,all(nine %in% names(before)),all(nine %in% names(after)))

# Before commencement each action carries exactly what its own aggregate
# carries, and the two sides differ: the modeled aggregate rate_s338 is 0 while
# the statutory aggregate is NA, because nothing source-backed establishes a
# duty that has not commenced. Each component must agree with the aggregate it
# sums into, so a modeled 0 and a statutory NA is the contract -- not 0 on both
# sides (which would assert a source-backed zero) and not NA on both (which is
# what bind_rows() used to fill, contradicting a modeled aggregate of 0).
stopifnot(all(before$rate_s338==0),all(is.na(before$statutory_rate_s338)))
for(col in paste0('modeled_rate_s338_',actions))
  stopifnot(!any(is.na(before[[col]])),all(before[[col]]==0))
for(col in paste0('statutory_rate_s338_',actions))
  stopifnot(all(is.na(before[[col]])),is.numeric(before[[col]]))
# The retained-legacy copies follow the statutory side they are renamed from,
# and so match the retained aggregate.
stopifnot(all(is.na(before$modeled_legacy_statutory_rate_s338)))
for(col in paste0('modeled_legacy_statutory_rate_s338_',actions))
  stopifnot(all(is.na(before[[col]])))

# The in-force state still charges, and charges the right action: beer under
# alcohol (9903.03.12) and milk under dairy (9903.03.13), each 50%. Both
# 8537109xxx lines read 0 here because the motor-vehicle scope does not reach
# them until the 2026-09-15 amendment (2026-18839) inserts them -- at this
# instant the original annex's 439 provisions govern, so a zero is the answer,
# not a gap.
stopifnot(after$modeled_rate_s338_alcohol[after$hts10=='2203000030']==.5,
          after$modeled_rate_s338_dairy[after$hts10=='0402101000']==.5,
          all(after$modeled_rate_s338_motor_vehicles==0),
          after$rate_s338[after$hts10=='2203000030']==.5,
          after$rate_s338[after$hts10=='0402101000']==.5,
          all(after$rate_s338[grepl('^8537',after$hts10)]==0),
          after$ch99_src_s338[after$hts10=='2203000030']=='9903.03.12',
          after$ch99_src_s338[after$hts10=='0402101000']=='9903.03.13')

# The invariant the split must preserve in BOTH states: the per-action columns
# are the decomposition of the aggregate, so they sum to it. This is what a
# ragged frame silently broke -- components absent on one state, present on the
# other, and the aggregate unchanged either way.
for(st in list(before,after)) {
  comp<-rowSums(as.data.frame(st[,paste0('modeled_rate_s338_',actions)]))
  stopifnot(isTRUE(all.equal(unname(comp),st$rate_s338)))
  retained<-rowSums(as.data.frame(st[,paste0('modeled_legacy_statutory_rate_s338_',actions)]))
  stopifnot(identical(is.na(retained),is.na(st$modeled_legacy_statutory_rate_s338)))
  if(!all(is.na(retained)))
    stopifnot(isTRUE(all.equal(unname(retained),st$modeled_legacy_statutory_rate_s338)))
}

# A revision that never reaches commencement asks for no actions and so gains no
# columns -- the 48 pre-§338 state computations in the rebuild must not change.
bare<-file.path(out,'bare');dir.create(bare,showWarnings=FALSE)
none<-calculate_rates_for_revision(products,ch99,NULL,NULL,'1220','2026_rev_16',
  as.Date('2026-08-14'),policy_params=pp,
  normalized_output_dir=bare,normalized_valid_until=as.Date('2026-08-21'))
stopifnot(!any(nine %in% names(none)))

cat('test_s338_legal_state_parity          PASS\n')
