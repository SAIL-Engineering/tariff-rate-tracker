suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/05_parse_policy_params.R')
source('src/resolve_country_scope.R');source('src/03_parse_chapter99.R')
# Original USTR investigation 23 expressly distinguishes Hong Kong from China.
# A comma inside its qualified name must not manufacture a second origin.
cases<-list(
 list('Hong Kong, China','5820'),
 list('HONG KONG ,  CHINA','5820'),
 list('China, Hong Kong',c('5700','5820')),
 list('Hong Kong, China or Taiwan',c('5820','5830')),
 list('Hong Kong, China and Canada',c('5820','1220')),
 list('Trinidad and Tobago or Hong Kong, China',c('2740','5820')),
 list('China or Hong Kong, China',c('5700','5820')))
lookup<-build_country_lookup('resources/census_codes.csv')
for(case in cases) {
 names<-extract_countries_from_description(paste('Articles the product of',case[[1]],', as provided for in subdivision (v)'))
 actual<-unique(unlist(lapply(names,resolve_country_name)))
 if(!setequal(actual,case[[2]]))stop('Qualified identity incorrectly split or list lost: ',case[[1]],' -> ',paste(actual,collapse=','))
 stopifnot(setequal(unlist(match_countries(names,lookup)$census_code),case[[2]]))
 if(!identical(case[[1]],'HONG KONG ,  CHINA')) {
   description<-paste('Articles the product of',case[[1]],', as provided for in U.S. note 52')
   stopifnot(setequal(resolve_country_scope(description)$census_codes,case[[2]]),
    setequal(parse_countries(description)$countries,case[[2]]))
 }
}
# Canonical/curated Census identity must agree across both ingestion resolvers.
for(name in c('Cabo Verde','Cape Verde'))stopifnot(unname(lookup[tolower(name)])==resolve_country_name(name))
stopifnot(identical(resolve_country_name('UK'),'4120'),
 is.na(match_countries('Congo',lookup)$census_code))
stopifnot(identical(resolve_country_name('Hong Kong, China'),'5820'),
 setequal(resolve_country_name('Hong Kong, China or Taiwan'),c('5820','5830')),
 !length(resolve_country_name('Hong Kong, China or Atlantis')))
census<-read.csv('resources/census_codes.csv',colClasses='character')
for(i in seq_len(nrow(census)))stopifnot(identical(resolve_country_name(census$Name[i]),census$Code[i]))
cat(length(cases),'qualified-identity and genuine-origin-list regressions passed\n')
