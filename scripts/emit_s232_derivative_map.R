#!/usr/bin/env Rscript
# =============================================================================
# Emit the Section 232 derivative product->Ch99 map (JSON) for the frontends
# =============================================================================
# Source of truth: resources/s232_derivative_products.csv (per-product US Note
# 16/19 subdivision membership, parsed from the Chapter 99 US Notes by
# scrape_us_notes.R and reviewed via the CSV diff gate).
#
# Purpose: until the data rebuild lands, the rates parquet / MotherDuck still
# carries the OLD pooled ch99_code_232 (the sort()[1] bug assigned 9903.85.04
# to every aluminum derivative). The frontend determination layer uses this
# map to resolve each product's own subdivision heading (e.g. 8536.90.85 ->
# 9903.85.08 per Note 19(k)) and to label the result as the reviewed-mapping
# source pending rebuild. After the rebuild, per-line ch99_rules_json takes
# precedence and this map becomes a cross-check.
#
#   Rscript scripts/emit_s232_derivative_map.R
# =============================================================================
suppressWarnings(suppressMessages({
  library(readr); library(dplyr); library(jsonlite); library(here)
}))

csv <- here('resources', 's232_derivative_products.csv')
if (!file.exists(csv)) stop('Missing resource: ', csv)
d <- read_csv(csv, col_types = cols(.default = col_character())) %>%
  filter(!is.na(ch99_code), !is.na(hts_prefix))

# One entry per (prefix, type): keep the code plus its effective window when
# present. Same-code rows differing only by effective_date collapse to the
# earliest start (the frontend only needs "is this code the product's own
# subdivision heading", not the batch history).
entries <- d %>%
  group_by(hts_prefix, derivative_type) %>%
  summarise(
    ch99_code = {
      codes <- unique(ch99_code)
      if (length(codes) > 1) {
        # Conflict: prefer the most specific subdivision (fewest products),
        # mirroring build_deriv_ch99_map() in src/helpers.R.
        sizes <- d %>% count(ch99_code) %>% filter(ch99_code %in% codes)
        sizes$ch99_code[which.min(sizes$n)]
      } else codes
    },
    effective_date = suppressWarnings(
      if (all(is.na(effective_date))) NA_character_ else min(effective_date, na.rm = TRUE)
    ),
    .groups = 'drop'
  )

prefixes <- setNames(
  lapply(seq_len(nrow(entries)), function(i) {
    e <- entries[i, ]
    out <- list(ch99_code = e$ch99_code, type = e$derivative_type)
    if (!is.na(e$effective_date)) out$effective_date <- e$effective_date
    out
  }),
  entries$hts_prefix
)

out <- list(
  version = 1,
  generated_from = 'resources/s232_derivative_products.csv',
  note = paste0('Per-product US Note 16/19 subdivision heading map. Used by the ',
                'frontend to resolve the legally correct derivative Ch99 code when ',
                'row data predates the per-product resolution (pre-rebuild).'),
  prefixes = prefixes
)
json <- toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = 'null')

targets <- c(
  here('frontend', 'public', 'data', 's232_derivative_map.json'),
  file.path('/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease',
            'sail-gtx-prerelease/src/modules/tariff-rates/constants/s232DerivativeMap.json')
)
for (t in targets) {
  dn <- dirname(t)
  if (!dir.exists(dn)) {
    ok <- dir.create(dn, recursive = TRUE, showWarnings = FALSE)
    if (!ok) { cat('  skip (no dir):', t, '\n'); next }
  }
  writeLines(json, t)
  cat('  wrote:', t, '\n')
}
cat('Derivative map:', nrow(entries), 'prefixes\n')
