# =============================================================================
# Run Daily Series from Parquet Dataset
# =============================================================================
#
# Loads the partitioned Parquet dataset one revision at a time and feeds
# the daily aggregation pipeline without requiring the monolithic RDS.
#
# Usage:
#   Rscript scripts/run_daily_from_parquet.R
# =============================================================================

library(tidyverse)
library(arrow)
library(here)

source(here("src", "helpers.R"))
source(here("src", "09_daily_series.R"))

ds <- open_rate_timeseries()

# Get revision list from the dataset
revisions <- ds %>%
  distinct(revision) %>%
  collect() %>%
  pull(revision)
message("Revisions in dataset: ", length(revisions))

# Load policy params for interval and expiry info
pp <- load_policy_params()
rev_dates <- load_revision_dates(use_policy_dates = TRUE)

horizon_end <- pp$SERIES_HORIZON_END %||% Sys.Date()
rev_intervals <- rev_dates %>%
  filter(revision %in% revisions) %>%
  arrange(effective_date) %>%
  mutate(valid_from = effective_date,
         valid_until = lead(effective_date) - 1) %>%
  mutate(valid_until = if_else(is.na(valid_until),
                               horizon_end, valid_until)) %>%
  select(revision, valid_from, valid_until)

# Process each revision one at a time through build_daily_aggregates
# by constructing the ts subset per revision
message("\nBuilding daily aggregates revision-by-revision...")

all_overall <- list()
all_by_country <- list()
all_by_authority <- list()

for (i in seq_len(nrow(rev_intervals))) {
  rev <- rev_intervals$revision[i]
  vf <- rev_intervals$valid_from[i]
  vu <- rev_intervals$valid_until[i]
  message("[", i, "/", nrow(rev_intervals), "] ", rev,
          " (", vf, " to ", vu, ")")

  # Load single revision from Parquet
  rev_ts <- ds %>%
    filter(revision == rev) %>%
    collect() %>%
    mutate(valid_from = vf, valid_until = vu)

  # Run daily aggregates for just this revision
  daily <- build_daily_aggregates(
    rev_ts,
    date_range = c(vf, vu),
    imports = NULL,
    policy_params = pp
  )

  all_overall[[i]] <- daily$daily_overall
  all_by_country[[i]] <- daily$daily_by_country
  all_by_authority[[i]] <- daily$daily_by_authority

  rm(rev_ts, daily)
  gc(verbose = FALSE)
}

# Combine the small daily aggregates (these are tiny — one row per day)
daily_overall <- bind_rows(all_overall) %>% arrange(date)
daily_by_country <- bind_rows(all_by_country) %>% arrange(date, country)
daily_by_authority <- bind_rows(all_by_authority) %>% arrange(date)

message("\nDaily overall rows: ", nrow(daily_overall))
message("Daily by country rows: ", nrow(daily_by_country))
message("Daily by authority rows: ", nrow(daily_by_authority))

# Save using the existing save function
daily <- list(
  daily_overall = daily_overall,
  daily_by_country = daily_by_country,
  daily_by_authority = daily_by_authority
)
save_daily_outputs(daily)

message("\n", strrep("=", 70))
message("DAILY SERIES COMPLETE (from Parquet)")
message(strrep("=", 70))
