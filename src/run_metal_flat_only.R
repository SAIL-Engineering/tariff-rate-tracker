# =============================================================================
# Run Metal Flat 100 Alternative Only
# =============================================================================
# Rebuilds the timeseries with flat 100% metal content shares, then
# pre-splits by revision before aggregation to reduce peak memory.
#
# Usage: Rscript src/run_metal_flat_only.R
# =============================================================================

library(here)
library(tidyverse)
library(jsonlite)
library(yaml)

source(here('src', 'helpers.R'))
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '05_parse_policy_params.R'))
source(here('src', '06_calculate_rates.R'))
source(here('src', '09_daily_series.R'))

pp <- load_policy_params()
imports <- load_import_weights()

message('\n', strrep('=', 70))
message('ALTERNATIVE: Flat 100% metal content shares')
message(strrep('=', 70))

pp_metal <- pp
pp_metal$metal_content$method <- 'flat'
pp_metal$metal_content$flat_share <- 1.0

# --- Rebuild timeseries (same as build_alternative_timeseries but without
#     calling build_daily_aggregates at the end) ---

calc_env <- environment(calculate_rates_for_revision)
original_pp <- calc_env$.pp
calc_env$.pp <- pp_metal
on.exit(calc_env$.pp <- original_pp, add = TRUE)

rev_dates <- load_revision_dates(here('config', 'revision_dates.csv'))
census_codes <- read_csv(here('resources', 'census_codes.csv'),
                         col_types = cols(.default = col_character()))
countries <- census_codes$Code
country_lookup <- build_country_lookup(here('resources', 'census_codes.csv'))

all_revisions <- rev_dates$revision
available <- get_available_revisions_all_years(all_revisions,
                                                here('data', 'hts_archives'))
revisions_to_process <- all_revisions[all_revisions %in% available]

snapshots <- list()
for (rev_id in revisions_to_process) {
  rev_info <- rev_dates %>% filter(revision == rev_id)
  eff_date <- rev_info$effective_date

  tryCatch({
    json_path <- resolve_json_path(rev_id, here('data', 'hts_archives'))
    hts_raw <- read_hts_archive(json_path)
    ch99_data <- parse_chapter99(json_path)
    products <- parse_products(json_path)
    ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup, effective_date = eff_date)
    fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup, effective_date = eff_date, revision_id = rev_id)
    s232_rates <- extract_section232_rates(ch99_data)
    usmca <- extract_usmca_eligibility(hts_raw)

    rates <- calculate_revision_legal_states(products,ch99_data,hts_raw,usmca,countries,
      rev_id,rev_dates,country_lookup,pp_metal,emit_normalized=FALSE)
    snapshots[[rev_id]] <- rates
    gc()
  }, error = function(e) {
    message('    SKIP ', rev_id, ': ', conditionMessage(e))
  })
}

if (length(snapshots) == 0) {
  stop('No snapshots built')
}

# Combine into timeseries
timeseries <- bind_rows(snapshots)
rm(snapshots); gc()

timeseries <- enforce_rate_schema(timeseries)
timeseries <- timeseries %>% arrange(effective_date, revision, country, hts10)

# Use the same interval-aware weighted aggregation as the main pipeline.
# Process one revision at a time to retain the bounded-memory behavior.
ts_split <- split(timeseries,timeseries$revision)
rm(timeseries);gc()
daily_overall <- bind_rows(lapply(ts_split,function(x)
  build_daily_aggregates(x,imports=imports,policy_params=pp_metal)$daily_overall))
daily_overall <- daily_overall %>% mutate(variant = 'metal_flat_100')

# Save
out_dir <- here('output', 'alternative')
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
write_csv(daily_overall, file.path(out_dir, 'daily_overall_metal_flat_100.csv'))
message('\nSaved: daily_overall_metal_flat_100.csv (', nrow(daily_overall), ' rows)')

message('\n', strrep('=', 70))
message('DONE')
message(strrep('=', 70))
