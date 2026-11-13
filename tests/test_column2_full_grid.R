# =============================================================================
# Column 2 reaches every non-NTR row, including the full-grid fill.
#
# calculate_rates_for_revision() re-based non-NTR origins on Column 2 at step 1a,
# but only on rows an authority had seeded. Pairs with no additional duty were
# added later by the full-grid fill (step 9c) straight from the General rate, so
# most Cuba / North Korea / Russia / Belarus rows carried a rate those origins do
# not pay. And where Column 2 did apply, the product tier join (step 9b) put the
# General rate's calc_status back over the Column 2 status.
#
# A bounded run on actual 2026_rev_19 source, not a revision rebuild.
# Run: Rscript tests/test_column2_full_grid.R
# =============================================================================

suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R'); source('src/logging.R'); source('src/03_parse_chapter99.R')
source('src/04_parse_products.R'); source('src/05_parse_policy_params.R'); source('src/06_calculate_rates.R')

revision <- '2026_rev_19'
path <- paste0('data/hts_archives/hts_', revision, '.json')
raw <- jsonlite::fromJSON(path, simplifyVector = FALSE)
#   0102294024  General 1¢/kg            Column 2 5.5¢/kg
#   2921460000  General Free             Column 2 15.4¢/kg + 149.5%
#   0101210010  General Free             Column 2 Free
selected <- c('0102294024', '2921460000', '0101210010')
chapter <- ''; kept <- list()
for (row in raw) {
  if (nzchar(row$htsno %||% '')) chapter <- substr(row$htsno, 1, 2)
  if (chapter %in% substr(selected, 1, 2)) kept[[length(kept) + 1L]] <- row
}
subset <- tempfile(fileext = '.json')
jsonlite::write_json(kept, subset, auto_unbox = TRUE, null = 'null')
products <- parse_products(subset) %>% filter(hts10 %in% selected); unlink(subset)
stopifnot(nrow(products) == 3L)

ch99 <- parse_chapter99(path, revision_id = revision)
eligibility <- extract_usmca_eligibility(raw)
out <- tempfile('column2-grid-'); dir.create(out)
save_ledger <- duty_ledger_save
duty_ledger_save <- function(...) save_ledger(dir = file.path(out, 'provenance'), ...)
Sys.setenv(SAIL_EMIT_NORMALIZED = '0')

# Cuba and Russia (non-NTR on 2026-09-15), China (NTR).
countries <- c('2390', '4621', '5700')
rates <- calculate_rates_for_revision(products, ch99, NULL, eligibility, countries, revision,
  as.Date('2026-09-15'), policy_params = load_policy_params())
unlink(out, recursive = TRUE)
stopifnot(nrow(rates) == 9L)

row_of <- function(h, c) rates[rates$hts10 == h & rates$country == c, , drop = FALSE]
for (c in c('2390', '4621')) {
  # Per-unit Column 2: no ad valorem part, owed in full, flagged.
  r <- row_of('0102294024', c)
  stopifnot(identical(r$base_rate_source, 'column2:specific_only'),
            identical(r$calc_status, 'needs_manual_review'),
            abs(r$base_rate - 0) < 1e-12)
  # Compound Column 2: the 149.5% applies, the 15.4¢/kg half is flagged.
  r <- row_of('2921460000', c)
  stopifnot(identical(r$base_rate_source, 'column2:compound'),
            identical(r$calc_status, 'needs_manual_review'),
            abs(r$base_rate - 1.495) < 1e-12,
            abs(r$statutory_base_rate - 1.495) < 1e-12,
            r$total_rate >= 1.495 - 1e-12)
  # Free on both columns: Column 2 applies and is complete.
  r <- row_of('0101210010', c)
  stopifnot(identical(r$base_rate_source, 'column2:free'),
            identical(r$calc_status, 'ok'))
}

# China keeps the General rate and the General rate's status.
r <- row_of('0102294024', '5700')
stopifnot(!grepl('^column2', dplyr::coalesce(r$base_rate_source, '')),
          identical(r$calc_status, 'base_ad_valorem_only'))
r <- row_of('2921460000', '5700')
stopifnot(!grepl('^column2', dplyr::coalesce(r$base_rate_source, '')), abs(r$base_rate - 0) < 1e-12)

cat('Column 2 re-bases every non-NTR row, seeded or filled, and its status survives the tier join\n')
