suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R')
source('src/07_emit_normalized.R')
# Primary CBP source, not expected values reverse-engineered from rate outputs.
text <- paste(readLines('resources/legal_evidence/section122/csms-67844987.txt', warn = FALSE), collapse = '\n')
section <- sub('.*The agricultural products described in subdivision', '', text)
section <- sub('Filers must ensure.*', '', section)
codes <- unique(gsub('\\.', '', unlist(regmatches(section,
  gregexpr('[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}', section)))))
stopifnot(length(codes) == 11)
ex <- readr::read_csv('resources/s122_exempt_products.csv', col_types = cols(.default = col_character()))
limited <- ex %>% filter(hts8 %in% codes)
stopifnot(nrow(limited) == 11, all(limited$condition == 'article_description'),
          all(nzchar(limited$condition_text)))
# Every statistical child, including unenumerated neighbors, remains conditioned.
children <- paste0(rep(codes, each = 2), c('00', '99'))
stopifnot(all(s122_exempt_share(children, statutory = TRUE) == 0))
stopifnot(all(s122_exempt_share(children) == 1)) # prior aggregate model explicitly preserved
stopifnot(s122_exempt_share('3917330000', statutory = TRUE) == 0)
stopifnot(abs(s122_exempt_share('3917330000') - 0.6794028757556119) < 1e-8)
# Missing or old condition data cannot certify a shipment exemption.
legacy <- tempfile(fileext = '.csv'); write_csv(tibble(hts8 = '12345678'), legacy)
stopifnot(inherits(try(s122_exempt_share('1234567800', legacy, statutory = TRUE), silent=TRUE), 'try-error'))
stopifnot(inherits(try(s122_exempt_share('1234567800', paste0(legacy,'missing')), silent=TRUE), 'try-error'))
# Normalized model projection preserves exact shares and legal conditions.
modeled <- tibble(hts10 = c(children[1], '3917330000'), exemption_share = c(1, 0.6794028757556119))
state <- list(s122 = list(in_force = TRUE, exempt_hts8 = ex$hts8, exemptions = ex, modeled_exemptions = modeled))
out <- tempfile(); dir.create(out)
r <- emit_authority_exemptions(NULL,NULL,NULL,'test','2026-03-10',out,denorm_state=state)
stopifnot(nrow(r) == 2, all(is.na(r$statutory_exemption_share)),
  setequal(r$shipment_condition, c('article_description','gn6_civil_aircraft')),
  all(is.na(r$hts_prefix)), identical(r$exemption_share, modeled$exemption_share))
state$s122$exemptions <- NULL
stopifnot(inherits(try(emit_authority_exemptions(NULL,NULL,NULL,'test','2026-03-10',out,denorm_state=state),silent=TRUE),'try-error'))
unlink(c(legacy,out),recursive=TRUE)
cat('Section 122 description/use scope, missing sources and normalized projection passed\n')

# Independently derive the adjusted-value exceptions from CBP's Chapter 98 paragraph.
ch98 <- sub('.*Chapter 98The additional duties', '', text)
ch98 <- sub('Foreign Trade Zones.*', '', ch98)
exceptions <- unique(gsub('\\.', '', unlist(regmatches(ch98,
  gregexpr('9802\\.00\\.[0-9]{2}', ch98)))))
stopifnot(length(exceptions) == 4)
adjusted <- ex %>% filter(hts8 %in% exceptions)
stopifnot(nrow(adjusted) == 4, all(adjusted$condition == 'chapter98_adjusted_value'),
          all(adjusted$valuation_basis != 'customs_value'))
stopifnot(all(s122_exempt_share(paste0(exceptions, '00'), statutory = TRUE) == 0),
          all(s122_exempt_share(paste0(exceptions, '00')) == 1))
cat('Chapter 98 adjusted-value exceptions are not unconditional shipment exemptions\n')

# A non-122 revision must have the same added field types for release unions.
out <- tempfile(); dir.create(out)
other <- emit_authority_exemptions('0101210010',NULL,NULL,'other','2025-01-01',out)
stopifnot(is.character(other$shipment_valuation_basis), all(is.na(other$shipment_valuation_basis)))
unlink(out,recursive=TRUE)
