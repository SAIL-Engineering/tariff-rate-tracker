suppressPackageStartupMessages({library(tidyverse);library(here)})
source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/resolve_rate_normalized.R')
lookup<-build_country_lookup('resources/census_codes.csv')
rows<-function(rev) emergency_source_rows(load_ieepa_emergency_source(rev),lookup)
early<-rows('2025_rev_3');late<-rows('2025_rev_27')
ordinary<-function(x,at) ordinary_emergency_parameters(select_ieepa_emergency_actions(x,at))
at<-ordinary(early,'2025-03-04T00:01:00-05:00')
stopifnot(at$fent_ch99[at$census_code=='5700']=='9903.01.24',at$fent_rate[at$census_code=='5700']==.2)
for(country in c('5700','5820')) {
  before<-ordinary(late,'2025-11-10T00:00:59-05:00')
  after<-ordinary(late,'2025-11-10T05:01:00Z')
  stopifnot(before$fent_rate[before$census_code==country]==.2,
    after$fent_rate[after$census_code==country]==.1,
    after$fent_ch99[after$census_code==country]=='9903.01.24')
}
ca<-ordinary(late,'2025-11-09T12:00:00-05:00') %>% filter(census_code=='1220')
stopifnot(ca$fent_rate==.35,ca$fent_ch99=='9903.01.10',
  late$entry_type[late$ch99_code=='9903.01.16']=='conditional_replacement',
  late$rate[late$ch99_code=='9903.01.16']==.4,
  late$census_code[late$ch99_code=='9903.01.13']=='1220')
active<-select_ieepa_emergency_actions(late,'2025-11-09T12:00:00-05:00')
stopifnot(identical(ordinary_emergency_parameters(active),ordinary_emergency_parameters(bind_rows(active,active))),
  identical(arrange(ordinary_emergency_parameters(active),census_code),
    arrange(ordinary_emergency_parameters(active[rev(seq_len(nrow(active))),]),census_code)))
bad<-active %>% filter(census_code=='1220',entry_type=='general');bad$rate<-.01
stopifnot(inherits(try(ordinary_emergency_parameters(bind_rows(active,bad)),silent=TRUE),'try-error'))
bad<-late;bad$valid_from[bad$ch99_code=='9903.01.10']<-'not a timestamp'
stopifnot(inherits(try(select_ieepa_emergency_actions(bad,'2025-11-09T12:00:00-05:00'),silent=TRUE),'try-error'))
# No raw heading-only country inference survives.
stopifnot(inherits(try(extract_ieepa_fentanyl_rates(list(list(htsno='9903.01.13',
  general='+10%',description='Energy without an identified origin')),lookup),silent=TRUE),'try-error'))
# Forward attribution preserves the energy heading even when the general
# heading has the same or a higher rate. No numeric matching is involved.
r<-enforce_rate_schema(tibble(hts10='2709000000',country='1220',rate_ieepa_fent=.1,ch99_src_ieepa_fent='9903.01.13'))
ch99<-tibble(ch99_code=c('9903.01.10','9903.01.13'),rate=c(.35,.1),authority='ieepa_fentanyl')
out<-resolve_ch99_codes(r,ch99,fentanyl_rates=active)
stopifnot(out$ch99_code_ieepa_fent=='9903.01.13')
x<-load_ieepa_emergency_source('2025_rev_27')
attr(active,'emergency_source')<-x;attr(active,'emergency_candidates')<-late
d<-emergency_action_decisions(active,active,'2025_rev_27')
stopifnot(nrow(d[d$decision=='ordinary_action_selected'&d$country=='5700',])==1,
  d$rate[d$decision=='ordinary_action_selected'&d$country=='5700']==.2,
  all(nchar(d$source_note_sha256)==64),all(nchar(d$source_note)>0))
cat('Emergency chronology, conditional replacements, source integrity, ambiguity and heading attribution passed\n')
ended<-emergency_action_decisions(active,NULL,'2026_rev_4','2026-02-24')
stopifnot(all(ended$terminated),all(ended$decision=='retired_heading'))
cat('Retained emergency evidence is marked retired after CBP collection ends\n')

source('src/resolve_rate_normalized.R')
acr<-active %>% transmute(authority='ieepa_fentanyl',program=paste0('fent_',entry_type),
  country=census_code,ch99_code,statutory_rate=rate,rate_type='surcharge')
winner<-tibble(authority='ieepa_fentanyl',program='fent_general',statutory_rate=NA_real_,
  ch99_code=NA_character_,deriv_type=NA_character_,scaling_dimension='none')
result<-.compute_authority_rate(winner,acr,NULL,'1220')
stopifnot(result$rate==.35,result$ch99_code=='9903.01.10')
winner$ch99_code<-'9903.01.13'
stopifnot(.compute_authority_rate(winner,acr,NULL,'1220')$rate==.1)
winner$ch99_code<-'9903.01.99'
stopifnot(is.na(.compute_authority_rate(winner,acr,NULL,'1220')$rate))
cat('Normalized emergency projection selects the same legal action and cannot replace a missing heading with a maximum\n')
# A later snapshot may reconstruct the original entry window, but cannot make
# March 7 potash relief available on March 4. Exact entry clocks stay separate
# from the daily aggregate convention.
for(at in c('2025-03-07T00:00:59-05:00','2025-03-07T00:01:00-05:00')) {
 selected<-select_ieepa_emergency_actions(late,at)
 potash<-selected$ch99_code %in% c('9903.01.05','9903.01.15')
 stopifnot(sum(potash)==if(grepl('00:00:59',at))0 else 2)
}
stopifnot(nrow(select_ieepa_emergency_actions(late,'2026-02-23T23:59:59-05:00'))>0,
          nrow(select_ieepa_emergency_actions(late,'2026-02-24T00:00:00-05:00'))==0,
          nrow(select_ieepa_emergency_actions(late,'2026-03-01',daily=TRUE))==0)
missing<-late;missing$valid_from[[1]]<-NA_character_
stopifnot(inherits(try(select_ieepa_emergency_actions(missing,'2025-03-07T00:01:00-05:00'),silent=TRUE),'try-error'))
missing<-late;missing$termination_source_ids<-''
stopifnot(inherits(try(select_ieepa_emergency_actions(missing,'2026-02-24T00:00:00-05:00'),silent=TRUE),'try-error'))
cat('March relief commencement, transit expiry and sourced midnight collection end passed\n')
