# =============================================================================
# Apply Tariff Scenarios
# =============================================================================
#
# Produces counterfactual rate estimates by transforming the standard rate
# schema. Scenarios are defined in config/scenarios.yaml and support two
# composable mechanisms:
#
#   disable: [auth, ...]   — zero out one or more authority columns wholesale
#                            (e.g., no_ieepa = [ieepa_reciprocal, ieepa_fentanyl]).
#                            Stacking rules are re-applied afterwards.
#
#   patches: [...]         — targeted, date-bounded rate overrides selected by
#                            country_group / product_set / from_date. Currently
#                            supports the `floor` action (sets all-in rate to a
#                            target value). See the PATCH DSL block below for
#                            the full filter + action vocabulary; see
#                            docs/scenarios.md for the authoring guide.
#
# Both formats may appear in the same scenario; patches are applied AFTER
# disable. Works on any tibble with the standard rate schema — a single
# revision snapshot or the full time series.
#
# =============================================================================

library(tidyverse)
library(yaml)

# NOTE: CTY_CHINA and AUTHORITY_COLUMNS loaded from YAML via helpers.R
.pp_08 <- tryCatch(load_policy_params(), error = function(e) NULL)
CTY_CHINA <- if (!is.null(.pp_08)) .pp_08$CTY_CHINA else '5700'
AUTHORITY_COLUMNS <- if (!is.null(.pp_08)) .pp_08$AUTHORITY_COLUMNS else c(
  'section_232'      = 'rate_232',
  'section_301'      = 'rate_301',
  'ieepa_reciprocal' = 'rate_ieepa_recip',
  'ieepa_fentanyl'   = 'rate_ieepa_fent',
  'section_122'      = 'rate_s122',
  'other'            = 'rate_other'
)


# =============================================================================
# Patch DSL — date-bounded targeted rate modifications
# =============================================================================
#
# A scenario may include a `patches:` list in addition to the legacy `disable:`.
# Each patch has shape:
#   filter:
#     country_group: 'eu' | 'china' | 'floor_countries' | <list of census codes>
#     product_set:   <key from PATCH_PRODUCT_SETS or section_232_headings>
#     from_date:     YYYY-MM-DD (optional; null = always active)
#   action:
#     type:   'floor'  (only type currently supported; see notes below)
#     column: 'rate_232' | 'rate_301' | ...
#     value:  numeric (e.g., 0.25)
#
# Floor semantics: rate := max(value - base_rate, 0). Mirrors the EU/JP/KR auto
# deal mechanism (06_calculate_rates.R:1745-1753) — sets the all-in rate
# (column + base_rate) to `value`, taking the max with 0 so we don't subsidize.
# =============================================================================

#' Named product sets that compose multiple section_232_headings entries
PATCH_PRODUCT_SETS <- list(
  auto_vehicles = c('autos_passenger', 'autos_light_trucks'),
  auto_parts    = c('auto_parts'),
  mhd_vehicles  = c('mhd_vehicles', 'buses'),
  mhd_parts     = c('mhd_parts')
)


#' Resolve a country_group filter to a vector of Census codes
#'
#' Accepts mnemonics ('eu', 'china', 'canada', 'mexico', 'uk', 'japan',
#' 'floor_countries', 'all') or a character vector of Census codes (passed
#' through unchanged).
#'
#' @param group Mnemonic string or character vector of codes
#' @param pp Policy params list (from load_policy_params())
#' @return Character vector of Census country codes, or NULL for 'all'
resolve_country_group <- function(group, pp = NULL) {
  if (is.null(group) || length(group) == 0) return(NULL)
  if (is.null(pp)) pp <- load_policy_params()

  if (length(group) > 1) {
    # explicit list of codes
    return(as.character(group))
  }

  switch(as.character(group),
    'all'    = NULL,
    'eu'     = pp$EU27_CODES,
    'china'  = pp$CTY_CHINA,
    'canada' = pp$CTY_CANADA,
    'mexico' = pp$CTY_MEXICO,
    'uk'     = pp$CTY_UK,
    'japan'  = pp$CTY_JAPAN,
    'floor_countries' = pp$floor_rates$floor_countries,
    # Fall through: assume single Census code
    as.character(group)
  )
}


#' Resolve a product_set filter to a vector of HTS prefixes
#'
#' Looks up named composites in PATCH_PRODUCT_SETS, then falls back to a single
#' heading name from `pp$section_232_headings`. Returns the union of all
#' `prefixes` arrays from the matched headings.
#'
#' @param set Mnemonic string (e.g., 'auto_vehicles') or single heading name
#' @param pp Policy params list
#' @return Character vector of HTS prefixes
resolve_product_set <- function(set, pp = NULL) {
  if (is.null(set) || length(set) == 0) return(character(0))
  if (is.null(pp)) pp <- load_policy_params()

  heading_names <- if (set %in% names(PATCH_PRODUCT_SETS)) {
    PATCH_PRODUCT_SETS[[set]]
  } else if (!is.null(pp$section_232_headings) &&
             set %in% names(pp$section_232_headings)) {
    set
  } else {
    stop('Unknown product_set: ', set,
         '. Known composites: ', paste(names(PATCH_PRODUCT_SETS), collapse = ', '),
         '; or any heading from policy_params.section_232_headings')
  }

  prefixes <- character(0)
  for (nm in heading_names) {
    cfg <- pp$section_232_headings[[nm]]
    if (is.null(cfg)) {
      stop('Heading missing from policy_params.section_232_headings: ', nm)
    }
    prefixes <- c(prefixes, as.character(unlist(cfg$prefixes)))
  }
  unique(prefixes)
}


#' Apply a single patch to a rates tibble
#'
#' Filters rows by country and product, then sets the target rate column
#' according to the action. Currently supports `type: floor` only (rate :=
#' max(value - base_rate, 0)).
#'
#' Stacking is NOT re-applied here — apply_scenario_spec() does it once after
#' all patches are applied so multiple patches don't re-stack repeatedly.
#'
#' @param rates Tibble with rate schema columns
#' @param patch Named list with $filter and $action
#' @param pp Policy params list (for resolving filters)
#' @return Modified rates tibble
apply_patch <- function(rates, patch, pp = NULL) {
  if (is.null(pp)) pp <- load_policy_params()

  filter_spec <- patch$filter %||% list()
  action <- patch$action %||% list()
  if (length(action) == 0) {
    stop('Patch missing $action')
  }

  countries <- resolve_country_group(filter_spec$country_group, pp)
  prefixes <- resolve_product_set(filter_spec$product_set, pp)
  if (length(prefixes) == 0) {
    stop('Patch resolved to empty product set: ', filter_spec$product_set)
  }

  prefix_pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')

  col <- action$column
  if (is.null(col) || !col %in% names(rates)) {
    stop('Patch action$column missing or not in rates: ', col)
  }
  type <- action$type %||% 'floor'
  value <- action$value
  if (type != 'floor') {
    stop('Patch action$type "', type, '" not supported; only "floor" is implemented')
  }
  if (is.null(value) || !is.numeric(value)) {
    stop('Patch action$value must be numeric')
  }

  match_rows <- grepl(prefix_pattern, rates$hts10)
  if (!is.null(countries)) {
    match_rows <- match_rows & rates$country %in% countries
  }

  if (!any(match_rows)) {
    return(rates)
  }

  # floor: rate := max(value - base_rate, 0)
  rates[[col]][match_rows] <- pmax(value - rates$base_rate[match_rows], 0)
  rates
}


# =============================================================================
# Scenario Functions
# =============================================================================

#' Load scenario definitions from YAML
#'
#' @param scenarios_path Path to scenarios.yaml
#' @return Named list of scenario definitions
load_scenarios <- function(scenarios_path = 'config/scenarios.yaml') {
  if (!file.exists(scenarios_path)) {
    stop('Scenarios config not found: ', scenarios_path)
  }

  scenarios <- read_yaml(scenarios_path)
  message('Loaded ', length(scenarios), ' scenarios from ', scenarios_path)

  return(scenarios)
}


#' Apply a pre-loaded scenario spec to a rates tibble
#'
#' Lower-level variant of apply_scenario() that takes a resolved scenario spec
#' (a named list with $disable, optional $patches, and optional $description)
#' instead of a name + file path. Use this when applying the same scenario
#' repeatedly in a loop — avoids re-reading scenarios.yaml on every call.
#'
#' Order of operations:
#'   1. Zero out columns listed in $disable (authority-level kill switch)
#'   2. Apply each patch in $patches whose filter$from_date is null or <=
#'      valid_from (date-bounded targeted rate edit)
#'   3. Re-apply stacking rules
#'
#' Patches with a `from_date` later than `valid_from` are skipped — the
#' scenario harness splits revision intervals at those dates so each
#' sub-interval sees a coherent on/off state.
#'
#' @param rates Tibble with standard rate columns
#' @param scenario_spec Named list with $disable, $patches, $description
#' @param scenario_name Character name to tag on the result (for traceability)
#' @param valid_from Date marking the start of the sub-interval being aggregated.
#'   Used to gate patches with `filter$from_date`. Defaults to NULL (apply all
#'   patches unconditionally — caller is responsible for date-splitting).
#' @param pp Policy params list (for resolving country/product filters in
#'   patches). NULL → load on demand.
#' @return Rates tibble with scenario applied and 'scenario' column added
apply_scenario_spec <- function(rates, scenario_spec, scenario_name = 'unnamed',
                                 valid_from = NULL, pp = NULL) {
  disable <- scenario_spec$disable %||% character(0)
  patches <- scenario_spec$patches %||% list()

  # Validate authority names
  invalid <- setdiff(disable, names(AUTHORITY_COLUMNS))
  if (length(invalid) > 0) {
    stop('Unknown authorities in scenario: ', paste(invalid, collapse = ', '),
         '\nValid: ', paste(names(AUTHORITY_COLUMNS), collapse = ', '))
  }

  # Zero out disabled columns
  result <- rates
  for (auth in disable) {
    col <- AUTHORITY_COLUMNS[auth]
    if (col %in% names(result)) {
      result[[col]] <- 0
    }
  }

  # Apply patches (date-gated)
  if (length(patches) > 0) {
    if (is.null(pp)) pp <- load_policy_params()
    for (patch in patches) {
      from_date <- patch$filter$from_date
      if (!is.null(from_date) && !is.null(valid_from)) {
        if (as.Date(valid_from) < as.Date(from_date)) next
      }
      result <- apply_patch(result, patch, pp = pp)
    }
  }

  # Re-apply stacking rules (shared implementation from helpers.R)
  result <- apply_stacking_rules(result, CTY_CHINA) %>%
    mutate(scenario = scenario_name)

  enforce_rate_schema(result)
}


#' Collect the from_date split points across all patches in a scenario
#'
#' Used by the harness to split revision intervals before aggregation so each
#' sub-interval falls cleanly on one side of every patch activation date.
#'
#' @param scenario_spec Named list (typically from scenarios.yaml)
#' @return Sorted vector of unique Date split points (may be empty)
collect_patch_split_dates <- function(scenario_spec) {
  patches <- scenario_spec$patches %||% list()
  if (length(patches) == 0) return(as.Date(character(0)))
  dates <- unlist(lapply(patches, function(p) p$filter$from_date))
  if (length(dates) == 0) return(as.Date(character(0)))
  sort(unique(as.Date(dates)))
}


#' Apply a scenario to a rates tibble
#'
#' Zeros out columns for disabled authorities, then re-applies stacking rules
#' to recompute total_additional and total_rate. Convenience wrapper around
#' apply_scenario_spec() that handles YAML loading and user-facing logging.
#'
#' @param rates Tibble with standard rate columns
#' @param scenario_name Name of scenario (must exist in scenarios YAML)
#' @param scenarios_path Path to scenarios.yaml
#' @return Rates tibble with scenario applied and 'scenario' column added
apply_scenario <- function(rates, scenario_name, scenarios_path = 'config/scenarios.yaml') {
  scenarios <- load_scenarios(scenarios_path)

  if (!scenario_name %in% names(scenarios)) {
    stop('Unknown scenario: ', scenario_name,
         '. Available: ', paste(names(scenarios), collapse = ', '))
  }

  scenario_spec <- scenarios[[scenario_name]]
  message('Applying scenario "', scenario_name, '": ', scenario_spec$description)
  disable <- scenario_spec$disable %||% character(0)
  if (length(disable) > 0) {
    message('  Disabling: ', paste(disable, collapse = ', '))
  }

  result <- apply_scenario_spec(rates, scenario_spec, scenario_name)
  message('  Mean total rate: ', round(mean(result$total_rate) * 100, 2), '%')
  result
}


#' Apply multiple scenarios and stack results
#'
#' @param rates Base rates tibble
#' @param scenario_names Vector of scenario names (or 'all' for all scenarios)
#' @param scenarios_path Path to scenarios.yaml
#' @return Combined tibble with all scenarios
apply_all_scenarios <- function(rates, scenario_names = 'all', scenarios_path = 'config/scenarios.yaml') {
  scenarios <- load_scenarios(scenarios_path)

  if (identical(scenario_names, 'all')) {
    scenario_names <- names(scenarios)
  }

  results <- map_dfr(scenario_names, function(name) {
    apply_scenario(rates, name, scenarios_path)
  })

  message('\nApplied ', length(scenario_names), ' scenarios')
  message('Total rows: ', nrow(results))

  return(results)
}


#' Compare two scenarios side by side
#'
#' @param rates Base rates tibble
#' @param scenario_a First scenario name
#' @param scenario_b Second scenario name
#' @param scenarios_path Path to scenarios.yaml
#' @return Tibble with difference metrics
compare_scenarios <- function(rates, scenario_a, scenario_b, scenarios_path = 'config/scenarios.yaml') {
  a <- apply_scenario(rates, scenario_a, scenarios_path)
  b <- apply_scenario(rates, scenario_b, scenarios_path)

  comparison <- a %>%
    select(hts10, country, revision, total_rate_a = total_rate) %>%
    inner_join(
      b %>% select(hts10, country, revision, total_rate_b = total_rate),
      by = c('hts10', 'country', 'revision')
    ) %>%
    mutate(
      diff = total_rate_a - total_rate_b,
      abs_diff = abs(diff)
    )

  message('\n=== Scenario Comparison: ', scenario_a, ' vs ', scenario_b, ' ===')
  message('Mean rate (', scenario_a, '): ', round(mean(comparison$total_rate_a) * 100, 2), '%')
  message('Mean rate (', scenario_b, '): ', round(mean(comparison$total_rate_b) * 100, 2), '%')
  message('Mean difference: ', round(mean(comparison$diff) * 100, 2), 'pp')
  message('Products affected: ', sum(comparison$abs_diff > 0.001))

  return(comparison)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Load latest snapshot or time series
  ts_path <- 'data/timeseries/rate_timeseries.rds'
  if (!file.exists(ts_path)) {
    # Fall back to single snapshot
    ts_path <- 'data/processed/rates_rev32.rds'
  }

  rates <- readRDS(ts_path)
  message('Loaded rates: ', nrow(rates), ' rows')

  # Apply all scenarios
  all_scenarios <- apply_all_scenarios(rates)

  # Summary by scenario
  cat('\n=== Scenario Summary ===\n')
  all_scenarios %>%
    group_by(scenario) %>%
    summarise(
      mean_total_rate = round(mean(total_rate) * 100, 2),
      mean_additional = round(mean(total_additional) * 100, 2),
      n_with_duties = sum(total_additional > 0),
      .groups = 'drop'
    ) %>%
    print()
}
