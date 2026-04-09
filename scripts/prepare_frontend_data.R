# =============================================================================
# Prepare Frontend Data (JSON)
# =============================================================================
#
# Generates JSON files in frontend/public/data/ for the frontend application.
#
# Output files:
#   1. countries.json          — merged Census + partner + ISO codes
#   2. revision_timeline.json  — revision dates and policy events
#   3. daily_overall.json      — daily overall tariff rates
#   4. daily_by_authority.json — daily rates by authority
#   5. daily_by_country_summary.json — one row per country per revision
#   6. sample_rates.json       — rate evolution for sample products (China)
#
# Usage:
#   Rscript scripts/prepare_frontend_data.R
# =============================================================================

library(jsonlite)
library(arrow)
suppressPackageStartupMessages(library(dplyr))
library(here)
suppressPackageStartupMessages(library(readr))

source(here("src", "helpers.R"))

output_dir <- here("frontend", "public", "data")
if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

message("Output directory: ", output_dir)

# =============================================================================
# 1. countries.json
# =============================================================================
message("\n--- 1. countries.json ---")

census <- load_census_codes() %>%
  rename(code = Code, name = Name)

partner_map <- load_country_partner_mapping()
names(partner_map) <- c("code", "partner", "country_name")

# Merge census + partner
countries <- census %>%
  left_join(partner_map %>% select(code, partner), by = "code")

# Match Census country names to ISO alpha-2/alpha-3 codes
countries <- match_census_to_iso(countries)

countries_out <- countries %>%
  mutate(
    partner = ifelse(is.na(partner), NA, partner),
    alpha2 = ifelse(is.na(alpha2), NA, alpha2),
    alpha3 = ifelse(is.na(alpha3), NA, alpha3)
  ) %>%
  select(code, name, partner, alpha2, alpha3)

write_json(countries_out, file.path(output_dir, "countries.json"),
           pretty = TRUE, na = "null", auto_unbox = TRUE)
message("  Wrote countries.json: ", nrow(countries_out), " rows, ",
        sum(!is.na(countries_out$alpha2)), " with ISO codes")

# =============================================================================
# 2. revision_timeline.json
# =============================================================================
message("\n--- 2. revision_timeline.json ---")

rev_dates <- read_csv(here("config", "revision_dates.csv"),
                      col_types = cols(.default = "c"),
                      show_col_types = FALSE)

rev_timeline <- rev_dates %>%
  transmute(
    revision = revision,
    effectiveDate = effective_date,
    policyEffectiveDate = ifelse(policy_effective_date == "" | is.na(policy_effective_date),
                                 NA, policy_effective_date),
    policyEvent = ifelse(policy_event == "" | is.na(policy_event),
                         NA, policy_event)
  )

write_json(rev_timeline, file.path(output_dir, "revision_timeline.json"),
           pretty = TRUE, na = "null", auto_unbox = TRUE)
message("  Wrote revision_timeline.json: ", nrow(rev_timeline), " rows")

# =============================================================================
# 3. daily_overall.json
# =============================================================================
message("\n--- 3. daily_overall.json ---")

daily_overall <- read_csv(here("output", "daily", "daily_overall.csv"),
                          show_col_types = FALSE)

write_json(daily_overall, file.path(output_dir, "daily_overall.json"),
           pretty = TRUE, na = "null", auto_unbox = TRUE, digits = NA)
message("  Wrote daily_overall.json: ", nrow(daily_overall), " rows")

# =============================================================================
# 4. daily_by_authority.json
# =============================================================================
message("\n--- 4. daily_by_authority.json ---")

daily_auth <- read_csv(here("output", "daily", "daily_by_authority.csv"),
                       show_col_types = FALSE)

write_json(daily_auth, file.path(output_dir, "daily_by_authority.json"),
           pretty = TRUE, na = "null", auto_unbox = TRUE, digits = NA)
message("  Wrote daily_by_authority.json: ", nrow(daily_auth), " rows")

# =============================================================================
# 5. daily_by_country_summary.json
# =============================================================================
message("\n--- 5. daily_by_country_summary.json ---")

daily_country <- read_csv(here("output", "daily", "daily_by_country.csv"),
                          show_col_types = FALSE)

# One row per country per revision: take the first date in each revision interval
country_summary <- daily_country %>%
  group_by(country, country_name, country_abbr, revision) %>%
  summarise(
    date = min(date),
    mean_additional_all_pairs = first(mean_additional_all_pairs[date == min(date)]),
    mean_total_all_pairs = first(mean_total_all_pairs[date == min(date)]),
    n_products_present = first(n_products_present[date == min(date)]),
    .groups = "drop"
  ) %>%
  arrange(country, date)

write_json(country_summary, file.path(output_dir, "daily_by_country_summary.json"),
           pretty = TRUE, na = "null", auto_unbox = TRUE, digits = NA)
message("  Wrote daily_by_country_summary.json: ", nrow(country_summary), " rows",
        " (", length(unique(country_summary$country)), " countries)")

# =============================================================================
# 6. sample_rates.json
# =============================================================================
message("\n--- 6. sample_rates.json ---")

ds <- tryCatch(open_rate_timeseries(), error = function(e) NULL)

if (is.null(ds)) {
  message("  WARNING: Parquet dataset not available. Skipping sample_rates.json")
  write_json(list(), file.path(output_dir, "sample_rates.json"),
             pretty = TRUE, auto_unbox = TRUE)
} else {
  # --- Data-driven sample selection (no hardcoded HTS codes or countries) ---
  # Configurable limits: override via policy_params or use defaults
  pp <- tryCatch(load_policy_params(), error = function(e) NULL)
  n_per_chapter <- if (!is.null(pp$sample_n_per_chapter)) pp$sample_n_per_chapter else 2
  n_sample_countries <- if (!is.null(pp$sample_n_countries)) pp$sample_n_countries else 15

  # Discover all chapters present in the dataset
  chapters <- ds %>%
    mutate(chapter = substr(hts10, 1, 2)) %>%
    distinct(chapter) %>%
    collect() %>%
    pull(chapter) %>%
    sort()
  # Exclude Chapter 99 (tariff provisions, not products)
  chapters <- chapters[chapters != "99"]

  message("  Discovered ", length(chapters), " product chapters in dataset")

  # Use the latest revision for sample selection (most representative rates)
  all_revisions <- ds %>% distinct(revision) %>% collect() %>% pull(revision)
  latest_rev <- sort(all_revisions, decreasing = TRUE)[1]
  message("  Selecting samples from latest revision: ", latest_rev)

  # For each chapter, pick products with highest rate variance across countries
  sample_hts <- character()
  for (ch in chapters) {
    candidates <- ds %>%
      filter(revision == latest_rev, substr(hts10, 1, 2) == ch) %>%
      group_by(hts10) %>%
      summarise(
        rate_var = var(total_additional, na.rm = TRUE),
        n_countries = n(),
        .groups = "drop"
      ) %>%
      filter(n_countries > 1) %>%
      arrange(desc(rate_var)) %>%
      head(n_per_chapter) %>%
      collect()
    sample_hts <- c(sample_hts, candidates$hts10)
  }
  message("  Selected ", length(sample_hts), " representative products across ",
          length(chapters), " chapters")

  # Select sample countries from the partner mapping (all partner groups represented)
  partner_map_full <- load_country_partner_mapping()
  names(partner_map_full) <- c("code", "partner", "country_name")
  # Ensure every partner group is represented, then fill with remaining countries
  partner_reps <- partner_map_full %>%
    group_by(partner) %>%
    slice_head(n = ceiling(n_sample_countries / n_distinct(partner_map_full$partner))) %>%
    ungroup()
  if (nrow(partner_reps) > n_sample_countries) {
    # Keep at least 1 per partner group, trim the rest
    guaranteed <- partner_map_full %>% group_by(partner) %>% slice_head(n = 1) %>% ungroup()
    remaining <- partner_reps %>% filter(!code %in% guaranteed$code)
    partner_reps <- bind_rows(
      guaranteed,
      remaining %>% slice_head(n = n_sample_countries - nrow(guaranteed))
    )
  }
  sample_countries <- unique(partner_reps$code)

  # Verify selected countries exist in dataset
  ds_countries <- get_all_country_codes_from_ds(ds)
  sample_countries <- intersect(sample_countries, ds_countries)
  message("  Selected ", length(sample_countries), " sample countries across all partner groups")

  if (length(sample_hts) > 0 && length(sample_countries) > 0) {
    sample_full <- query_rates(ds,
                               countries = sample_countries,
                               hts_codes = sample_hts) %>%
      collect() %>%
      arrange(hts10, country, effective_date)

    message("  Sample dataset: ", nrow(sample_full), " rows, ",
            length(unique(sample_full$hts10)), " products, ",
            length(unique(sample_full$country)), " countries, ",
            length(unique(sample_full$revision)), " revisions")

    write_json(sample_full, file.path(output_dir, "sample_rates.json"),
               pretty = TRUE, na = "null", auto_unbox = TRUE, digits = NA)
    message("  Wrote sample_rates.json: ",
            round(file.size(file.path(output_dir, "sample_rates.json")) / 1024, 1), " KB")
  } else {
    message("  WARNING: No sample data found. Writing empty array.")
    write_json(list(), file.path(output_dir, "sample_rates.json"),
               pretty = TRUE, auto_unbox = TRUE)
  }
}

# =============================================================================
# Summary
# =============================================================================
message("\n=== All JSON files ===")
json_files <- list.files(output_dir, pattern = "\\.json$", full.names = TRUE)
for (f in json_files) {
  sz <- file.size(f)
  unit <- if (sz > 1e6) paste0(round(sz / 1e6, 1), " MB") else paste0(round(sz / 1e3, 1), " KB")
  message("  ", basename(f), ": ", unit)
}

message("\nDone.")
