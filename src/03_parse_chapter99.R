# =============================================================================
# Step 03: Parse Chapter 99 Entries
# =============================================================================
#
# Extracts Chapter 99 subheadings from HTS JSON and parses:
#   - Rate (from 'general' field)
#   - Country applicability (from 'description' field)
#   - Authority type (inferred from subheading range)
#
# Output: chapter99_rates.rds with columns:
#   - ch99_code: Chapter 99 subheading (e.g., "9903.88.15")
#   - rate: Additional duty rate (numeric, e.g., 0.25 for 25%)
#   - authority: Inferred authority (section_232, section_301, ieepa, etc.)
#   - country_type: Scope type ("specific", "all", "all_except", "unknown")
#   - countries: List of country codes (if country_type = "specific")
#   - exempt_countries: List of exempt countries (if country_type = "all_except")
#   - references: List of cross-referenced ch99 codes (e.g., c("9903.01.02", "9903.01.03"))
#   - resolution_status: Triage of country scope resolution (see classify_resolution_status())
#   - description: Original description text
#   - general_raw: Original general rate text
#
# =============================================================================

library(tidyverse)
library(jsonlite)

# NOTE: parse_ch99_rate() and classify_authority() are defined in helpers.R
# This file uses those shared versions.


# =============================================================================
# Country Parsing Functions
# =============================================================================

#' Parse country applicability from description
#'
#' Extracts country information from descriptions like:
#'   "articles the product of China..."
#'   "except products of Australia, of Canada, of Mexico..."
#'
#' @param description Description text
#' @return List with 'type' and 'countries'
parse_countries <- function(description) {
  if (is.null(description) || is.na(description) || description == '') {
    return(list(type = 'unknown', countries = character(0), exempt = character(0)))
  }

  desc_lower <- tolower(description)

  # Check for "product of China" pattern
  if (str_detect(desc_lower, 'product of china')) {
    return(list(type = 'specific', countries = c('CN'), exempt = character(0)))
  }

  # US Note 31 = Biden Section 301 increases (China-specific)
  if (str_detect(desc_lower, 'u\\.s\\.\\s*note\\s*31')) {
    return(list(type = 'specific', countries = c('CN'), exempt = character(0)))
  }

  # Check for "product of Canada" pattern
  if (str_detect(desc_lower, 'product of canada')) {
    countries <- c('CA')
    if (str_detect(desc_lower, 'mexico')) {
      countries <- c(countries, 'MX')
    }
    return(list(type = 'specific', countries = countries, exempt = character(0)))
  }

  # Check for "except" clauses that reference HTS headings, not countries.
  # e.g., "Except for derivative iron or steel products described in headings 9903.81.89..."
  # These are blanket rates — the "except" carves out other HTS codes, not countries.
  if (str_detect(desc_lower, 'except.*(?:heading|subheading|9903)')) {
    if (!any(str_detect(desc_lower, c('canada', 'mexico', 'japan', 'korea',
                                       'kingdom', 'european', 'russia')))) {
      return(list(type = 'all', countries = character(0), exempt = character(0)))
    }
  }

  # Check for "except products of..." pattern (Section 232 style)
  except_match <- str_match(desc_lower, 'except[^,]*(products? of|of)\\s+([^,]+(?:,\\s*(?:of\\s+)?[^,]+)*)')
  if (!is.na(except_match[1, 1])) {
    # Extract country names from the exception list
    except_text <- except_match[1, 3]
    exempt <- extract_country_names(except_text)
    return(list(type = 'all_except', countries = character(0), exempt = exempt))
  }

  # Check for "product of the Russian Federation"
  if (str_detect(desc_lower, 'russian federation')) {
    return(list(type = 'specific', countries = c('RU'), exempt = character(0)))
  }

  # Country-specific "products of [country]" or "[items] of the [country]" pattern
  # (Section 232 deals, wood tariffs)
  # e.g., "Passenger vehicles that are products of the United Kingdom"
  #        "Wood products of Japan as provided for..."
  #        "...products of the European Union..."
  #        "...parts of passenger vehicles and light trucks of the United Kingdom..."
  #        "...products of South Korea..."
  country_specific_map <- c(
    'united kingdom' = 'UK', 'japan' = 'JP',
    'european union' = 'EU', 'south korea' = 'KR', 'korea' = 'KR'
  )
  for (name in names(country_specific_map)) {
    if (str_detect(desc_lower, paste0('\\bof\\s+(the\\s+)?', name))) {
      return(list(type = 'specific',
                  countries = country_specific_map[name],
                  exempt = character(0)))
    }
  }

  # Default: unknown — downstream consumers must opt into 'all' explicitly.
  # Returning 'unknown' instead of 'all' prevents a parser miss from silently

  # promoting a country-specific or all_except entry to a global blanket tariff.
  return(list(type = 'unknown', countries = character(0), exempt = character(0)))
}


#' Extract country names from text
#'
#' @param text Text containing country names
#' @return Vector of ISO country codes
extract_country_names <- function(text) {
  # Map of country names to ISO codes
  country_map <- c(
    'australia' = 'AU', 'argentina' = 'AR', 'brazil' = 'BR',
    'canada' = 'CA', 'mexico' = 'MX', 'china' = 'CN',
    'people\'s republic of china' = 'CN',
    'south korea' = 'KR', 'korea' = 'KR',
    'japan' = 'JP', 'united kingdom' = 'UK', 'uk' = 'UK',
    'european union' = 'EU', 'eu' = 'EU',
    'ukraine' = 'UA', 'russia' = 'RU', 'russian federation' = 'RU',
    'india' = 'IN', 'switzerland' = 'CH', 'liechtenstein' = 'LI',
    'thailand' = 'TH', 'vietnam' = 'VN', 'viet nam' = 'VN',
    'taiwan' = 'TW', 'indonesia' = 'ID'
  )

  text_lower <- tolower(text)
  found <- character(0)

  for (name in names(country_map)) {
    if (str_detect(text_lower, name)) {
      found <- c(found, country_map[name])
    }
  }

  unique(found)
}


#' Extract cross-references to other Chapter 99 codes from description text
#'
#' Many ch99 entries reference other 9903.xx.xx codes (e.g., "Except for products
#' described in headings 9903.01.02, 9903.01.03..."). This function extracts those
#' references to make the dependency graph visible.
#'
#' @param description Description text
#' @return Character vector of referenced ch99 codes (unique, sorted)
extract_ch99_references <- function(description) {
  if (is.null(description) || is.na(description) || description == '') {
    return(character(0))
  }
  refs <- str_extract_all(description, '9903\\.[0-9]{2}\\.[0-9]{2}')[[1]]
  sort(unique(refs))
}


#' Classify the resolution status of a ch99 entry's country scope
#'
#' Entries with country_type = 'unknown' from parse_countries() may still be
#' handled correctly by authority-specific extractors downstream. This function
#' classifies each entry so warnings distinguish genuinely unresolved entries
#' from those handled by other code paths.
#'
#' @param ch99_code Character vector of ch99 codes
#' @param country_type Character vector of country types from parse_countries()
#' @return Character vector of resolution statuses
classify_resolution_status <- function(ch99_code, country_type) {
  case_when(
    country_type != 'unknown' ~ 'resolved_by_parser',
    # Section 122 (post-IEEPA blanket authority): 9903.03.xx
    # — handled by extract_section122_rate() + s122 logic in calculate_rates_for_revision()
    grepl('^9903\\.03\\.', ch99_code) ~ 'handled_by_s122_config',
    # IEEPA fentanyl/initial: 9903.01.01-24 — handled by extract_ieepa_fentanyl_rates()
    grepl('^9903\\.01\\.(0[1-9]|1[0-9]|2[0-4])$', ch99_code) ~ 'handled_by_fentanyl_extractor',
    # IEEPA exclusions/exemptions: 9903.01.25-42 — donations, informational materials,
    # USMCA, general note 11, etc. These define what's EXCLUDED from IEEPA.
    # Extractors handle surcharge entries; exclusions are implicit (no rate to apply).
    grepl('^9903\\.01\\.(2[5-9]|3[0-9]|4[0-2])$', ch99_code) ~ 'ieepa_exclusion_no_rate',
    grepl('^9903\\.01\\.9[0-9]$', ch99_code) ~ 'ieepa_exclusion_no_rate',
    grepl('^9903\\.02\\.01$', ch99_code) ~ 'ieepa_exclusion_no_rate',
    # Civil-aircraft exclusions: 9903.96.xx carry "The duty provided in the
    # applicable subheading" / "No change" (WTO Agreement on Trade in Civil
    # Aircraft + 2025 aircraft deals). No additional duty — an exclusion, not a
    # missing tariff. (e.g. 9903.96.03 = Taiwan civil-aircraft components.)
    grepl('^9903\\.96', ch99_code) ~ 'ieepa_exclusion_no_rate',
    # IEEPA reciprocal Phase 1: 9903.01.43-89 — handled by extract_ieepa_rates()
    grepl('^9903\\.01\\.(4[3-9]|[5-8][0-9])$', ch99_code) ~ 'handled_by_ieepa_extractor',
    # IEEPA reciprocal Phase 2 + Swiss framework: 9903.02.02-91
    grepl('^9903\\.02\\.(0[2-9]|[1-8][0-9]|9[01])$', ch99_code) ~ 'handled_by_ieepa_extractor',
    # Section 232 MHD vehicles: 9903.74.xx — handled by extract_section232_rates()
    # (auto_deal_rates logic)
    grepl('^9903\\.74', ch99_code) ~ 'handled_by_s232_extractor',
    # Section 232 wood products: 9903.76.xx — handled by extract_section232_rates()
    # (wood deals logic)
    grepl('^9903\\.76', ch99_code) ~ 'handled_by_s232_extractor',
    # Section 232 copper: 9903.78.xx — handled by extract_section232_rates()
    # (copper heading logic + product list from scrape_us_notes.R)
    grepl('^9903\\.78', ch99_code) ~ 'handled_by_s232_extractor',
    # Section 232 steel/aluminum: 9903.80-85, 9903.94
    grepl('^9903\\.8[0-5]', ch99_code) ~ 'handled_by_s232_extractor',
    grepl('^9903\\.94', ch99_code) ~ 'handled_by_s232_extractor',
    # Section 232 semiconductors: 9903.79.xx — handled by extract_section232_rates()
    # (semi_rate read from 9903.79.01; per-HTS10 qualifying_share + end-use
    # blending applied in calculate_rates_for_revision; US Note 39, eff 2026-01-16).
    grepl('^9903\\.79', ch99_code) ~ 'handled_by_s232_extractor',
    # Section 301 China-specific: 9903.88-93 — handled via policy_params.yaml
    grepl('^9903\\.(88|89|9[0-3])', ch99_code) ~ 'handled_by_s301_config',
    # WTO tariff-rate quotas (TRQs): not duty-relevant surcharges
    grepl('^9903\\.(04|08|17|18|19|27|52|53|54|55)', ch99_code) ~ 'not_duty_relevant_trq',
    # Section 201 SOLAR safeguard (CSPV cells/modules, 9903.45.21–.29) — MODELED
    # by extract_section_201_rates(): applies the configured solar_rate over the
    # HTS Year-1 rate (US Note; Proc 9693 as extended to 2026). G4 backport.
    grepl('^9903\\.45\\.2[1-9]', ch99_code) ~ 'handled_by_s201_extractor',
    # Other Section 201 ranges (tires 9903.40; CSPV-cell/washer tiers 9903.41;
    # washing machines 9903.45.0x): legacy safeguards retained in the HTS but
    # not modeled here — needs review (confirm expiry vs. model).
    grepl('^9903\\.(40|41|45)', ch99_code) ~ 'unresolved_s201',
    # Truly unresolved — needs investigation
    TRUE ~ 'unresolved'
  )
}


# =============================================================================
# Main Parsing Function
# =============================================================================

#' Parse all Chapter 99 entries from HTS JSON
#'
#' @param json_path Path to HTS JSON file
#' @param revision_id Optional revision ID for log messages (e.g., "2025_rev_7")
#' @return Tibble with parsed Chapter 99 data including resolution_status and references columns
parse_chapter99 <- function(json_path, revision_id = NULL) {
  message('Reading HTS JSON from: ', json_path)

  # Read JSON
  hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  message('  Total items: ', length(hts_raw))

  # Filter to Chapter 99 entries (9903.xx.xx)
  ch99_items <- Filter(function(x) {
    htsno <- x$htsno %||% ''
    grepl('^9903\\.', htsno)
  }, hts_raw)

  message('  Chapter 99 entries: ', length(ch99_items))

  # Parse each entry
  parsed <- map_dfr(ch99_items, function(item) {
    ch99_code <- item$htsno %||% NA_character_
    general <- item$general %||% ''
    other <- item$other %||% ''
    description <- item$description %||% ''

    # Parse rate from general or other column
    rate <- parse_ch99_rate(general)
    if (is.na(rate)) {
      rate <- parse_ch99_rate(other)
    }

    # Classify authority
    authority <- classify_authority(ch99_code)

    # Parse countries
    country_info <- parse_countries(description)

    # Extract cross-references to other ch99 codes
    refs <- extract_ch99_references(description)

    # Extract a legal effective-date offset from the description, if any
    # (e.g., "...effective with respect to entries on or after April 3, 2025...").
    # Used by filter_active_ch99() to drop entries that exist in the HTS but
    # aren't yet legally collectible at the revision's effective_date.
    eff_offset <- extract_effective_date_offset(description)

    tibble(
      ch99_code = ch99_code,
      rate = rate,
      authority = authority,
      country_type = country_info$type,
      countries = list(country_info$countries),
      exempt_countries = list(country_info$exempt),
      references = list(refs),
      general_raw = general,
      other_raw = other,
      description = description,
      effective_date_offset = eff_offset
    )
  })

  # Add resolution_status: classifies whether 'unknown' entries are actually
  # handled by downstream authority-specific extractors, are not duty-relevant,
  # or are genuinely unresolved.
  parsed <- parsed %>%
    mutate(resolution_status = classify_resolution_status(ch99_code, country_type))

  # Summary
  rev_label <- if (!is.null(revision_id)) paste0(' [', revision_id, ']') else ''
  message('\n=== Chapter 99 Summary', rev_label, ' ===')
  message('  Total entries: ', nrow(parsed))
  message('  With parsed rates: ', sum(!is.na(parsed$rate)))
  message('  By authority:')

  auth_summary <- parsed %>%
    count(authority, sort = TRUE)
  print(auth_summary)

  message('\n  By country type:')
  cty_summary <- parsed %>%
    count(country_type, sort = TRUE)
  print(cty_summary)

  # Triage unknown country types: distinguish entries handled downstream from
  # genuinely unresolved ones. Log to both console and build log file.
  unknown_entries <- parsed %>% filter(country_type == 'unknown')
  if (nrow(unknown_entries) > 0) {
    # Triage breakdown
    triage <- unknown_entries %>% count(resolution_status, sort = TRUE)
    triage_str <- paste(triage$n, triage$resolution_status, sep = ' ', collapse = ', ')
    truly_unresolved <- unknown_entries %>%
      filter(resolution_status %in% c('unresolved', 'unresolved_s201'))

    log_warn('Ch99 country scope', rev_label, ': ', nrow(unknown_entries),
             ' entries with unknown country_type (',  triage_str, ')')

    if (nrow(truly_unresolved) > 0) {
      log_warn('Truly unresolved entries (', nrow(truly_unresolved), '):')
      for (i in seq_len(min(nrow(truly_unresolved), 15))) {
        log_warn('  ', truly_unresolved$ch99_code[i], ' [', truly_unresolved$authority[i],
                 ']: "', substr(truly_unresolved$description[i], 1, 80), '..."')
      }
      if (nrow(truly_unresolved) > 15) {
        log_warn('  ... and ', nrow(truly_unresolved) - 15, ' more')
      }
    } else {
      log_info('All unknown-country entries are handled by downstream extractors or are not duty-relevant.')
    }

    # Log entries with cross-references for visibility
    has_refs <- unknown_entries %>% filter(lengths(references) > 0)
    if (nrow(has_refs) > 0) {
      log_info('Ch99 cross-references detected in ', nrow(has_refs), ' unknown entries')
    }
  }

  message('\n  By resolution status:')
  res_summary <- parsed %>% count(resolution_status, sort = TRUE)
  print(res_summary)

  return(parsed)
}


#' Chapter 99 completeness check — no active heading may be silently dropped
#'
#' Every active 9903 heading with a parsed positive rate must terminate in one
#' of: handled by an authority extractor/parser, classified not-duty-relevant,
#' or explicitly allowlisted (config/ch99_unresolved_allowlist.csv, reviewed).
#' Unresolved-WITH-RATE headings previously melted silently into rate_other —
#' that is now a build failure for trade-war-era revisions (2025+) unless
#' SAIL_CH99_STRICT=0. A per-revision coverage report CSV is always written.
#'
#' @param ch99_data Parsed 9903 data (with rate, resolution_status)
#' @param ch99_other Parsed 9902/9904 data (counts reported)
#' @param revision_id Revision ID (strictness gates on year >= 2025)
#' @param output_dir Where to write ch99_coverage_<rev>.csv (NULL = skip)
#' @return Invisibly, the coverage tibble
check_ch99_completeness <- function(ch99_data, ch99_other = NULL,
                                    revision_id = NULL, output_dir = NULL) {
  coverage <- ch99_data %>%
    count(authority, resolution_status, name = 'n_headings') %>%
    arrange(authority, resolution_status)

  if (!is.null(ch99_other) && nrow(ch99_other) > 0) {
    coverage <- bind_rows(
      coverage,
      ch99_other %>%
        count(subchapter, name = 'n_headings') %>%
        transmute(authority = subchapter,
                  resolution_status = 'candidate_requires_more_facts',
                  n_headings)
    )
  }

  if (!is.null(output_dir) && !is.null(revision_id)) {
    out_path <- file.path(output_dir, paste0('ch99_coverage_', revision_id, '.csv'))
    tryCatch(readr::write_csv(coverage, out_path), error = function(e) NULL)
  }

  # Unresolved WITH a positive parsed rate = a duty we could be silently
  # dropping. Allowlist is the reviewed escape hatch.
  unresolved_rated <- ch99_data %>%
    filter(resolution_status %in% c('unresolved', 'unresolved_s201'),
           !is.na(rate), rate > 0)

  allow_path <- here('config', 'ch99_unresolved_allowlist.csv')
  allowed <- if (file.exists(allow_path)) {
    readr::read_csv(allow_path, col_types = readr::cols(.default = readr::col_character()))$ch99_code
  } else character(0)
  offenders <- unresolved_rated %>% filter(!ch99_code %in% allowed)

  if (nrow(offenders) > 0) {
    rev_year <- suppressWarnings(as.integer(substr(revision_id %||% '', 1, 4)))
    strict <- !identical(Sys.getenv('SAIL_CH99_STRICT', '1'), '0') &&
      !is.na(rev_year) && rev_year >= 2025
    msg <- paste0(
      'Chapter 99 completeness: ', nrow(offenders), ' active heading(s) with a ',
      'parsed rate are unresolved and not allowlisted: ',
      paste(utils::head(offenders$ch99_code, 10), collapse = ', '),
      if (nrow(offenders) > 10) ' ...' else '',
      '. Resolve via an authority extractor or add to ',
      'config/ch99_unresolved_allowlist.csv with a review note.'
    )
    if (strict) stop(msg) else warning(msg)
  }

  invisible(coverage)
}


#' Parse non-9903 Chapter 99 provisions (9902 MTB suspensions, 9904 safeguards)
#'
#' 9902 entries are Miscellaneous Tariff Bill temporary duty suspensions or
#' reductions (they REDUCE duty); 9904 entries are agricultural safeguards /
#' TRQ tiers (Chapter 99 Subchapter IV). Neither is integrated into the rate
#' math yet — this pass surfaces them as candidate rules with status
#' `potentially_applicable_requires_more_facts` in ch99_rules_json so the
#' determination layer can disclose them instead of silently omitting them.
#'
#' Trigger extraction: 9902 descriptions cite the covered subheading inline
#' ("provided for in subheading 0710.80.70") — extracted as HTS8 prefixes.
#' 9904 value-tier lines usually carry their product scope on parent headings
#' / Additional U.S. Notes, not inline; entries without an inline reference
#' get an empty trigger set and are reported at chapter level by the coverage
#' QC rather than attached per line.
#'
#' @param json_path Path to HTS JSON (used if hts_raw not supplied)
#' @param hts_raw Pre-read HTS JSON list (avoids a second file read)
#' @param revision_id Optional revision ID for log messages
#' @return Tibble: ch99_code, subchapter, rate_text, description, trigger_hts (list-col)
parse_chapter99_other <- function(json_path = NULL, hts_raw = NULL, revision_id = NULL) {
  if (is.null(hts_raw)) {
    stopifnot(!is.null(json_path))
    hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  }

  other_items <- Filter(function(x) {
    grepl('^990[24]\\.[0-9]{2}\\.[0-9]{2}', x$htsno %||% '')
  }, hts_raw)

  empty <- tibble(
    ch99_code = character(0), subchapter = character(0),
    rate_text = character(0), description = character(0),
    trigger_hts = list()
  )
  if (length(other_items) == 0) return(empty)

  parsed <- map_dfr(other_items, function(item) {
    code <- item$htsno %||% NA_character_
    desc <- item$description %||% ''
    general <- item$general %||% ''
    trigs <- str_extract_all(desc, '[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}')[[1]]
    trigs <- trigs[!grepl('^99', trigs)]
    tibble(
      ch99_code = code,
      subchapter = if_else(startsWith(code, '9902'), 'mtb_9902', 'ag_safeguard_9904'),
      rate_text = general,
      description = desc,
      trigger_hts = list(unique(gsub('\\.', '', trigs)))
    )
  })

  rev_label <- if (!is.null(revision_id)) paste0(' [', revision_id, ']') else ''
  n_9902 <- sum(parsed$subchapter == 'mtb_9902')
  n_9904 <- sum(parsed$subchapter == 'ag_safeguard_9904')
  n_trig <- sum(lengths(parsed$trigger_hts) > 0)
  message('  Chapter 99 other provisions', rev_label, ': ', n_9902,
          ' x 9902 (MTB), ', n_9904, ' x 9904 (ag safeguard); ',
          n_trig, ' with inline HTS triggers')

  parsed
}


#' Compare Chapter 99 entries between two HTS versions
#'
#' @param old_ch99 Parsed Chapter 99 from older version
#' @param new_ch99 Parsed Chapter 99 from newer version
#' @return List with added, removed, and changed entries
compare_chapter99 <- function(old_ch99, new_ch99) {
  old_codes <- old_ch99$ch99_code
  new_codes <- new_ch99$ch99_code

  added <- setdiff(new_codes, old_codes)
  removed <- setdiff(old_codes, new_codes)

  # Check for rate changes in common codes
  common <- intersect(old_codes, new_codes)

  old_rates <- old_ch99 %>%
    filter(ch99_code %in% common) %>%
    select(ch99_code, rate_old = rate)

  new_rates <- new_ch99 %>%
    filter(ch99_code %in% common) %>%
    select(ch99_code, rate_new = rate)

  rate_changes <- old_rates %>%
    inner_join(new_rates, by = 'ch99_code') %>%
    filter(!is.na(rate_old) & !is.na(rate_new)) %>%
    filter(abs(rate_old - rate_new) > 0.0001)

  list(
    added = new_ch99 %>% filter(ch99_code %in% added),
    removed = old_ch99 %>% filter(ch99_code %in% removed),
    rate_changes = rate_changes,
    n_added = length(added),
    n_removed = length(removed),
    n_rate_changes = nrow(rate_changes)
  )
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Parse the most recent revision (has all entries)
  ch99_rev32 <- parse_chapter99('data/hts_archives/hts_2025_rev_32.json')

  # Also parse baseline for comparison
  ch99_basic <- parse_chapter99('data/hts_archives/hts_2025_basic.json')

  # Compare
  cat('\n=== Changes from Basic to Rev 32 ===\n')
  changes <- compare_chapter99(ch99_basic, ch99_rev32)
  cat('Added entries:', changes$n_added, '\n')
  cat('Removed entries:', changes$n_removed, '\n')
  cat('Rate changes:', changes$n_rate_changes, '\n')

  if (changes$n_added > 0) {
    cat('\nNewly added Chapter 99 entries:\n')
    print(changes$added %>% select(ch99_code, rate, authority, country_type))
  }

  # Save
  if (!dir.exists('data/processed')) dir.create('data/processed', recursive = TRUE)
  saveRDS(ch99_rev32, 'data/processed/chapter99_rates.rds')
  message('\nSaved Chapter 99 data to data/processed/chapter99_rates.rds')

  # Also save as CSV for review
  ch99_rev32 %>%
    mutate(
      countries_str = map_chr(countries, ~paste(.x, collapse = ';')),
      exempt_str = map_chr(exempt_countries, ~paste(.x, collapse = ';'))
    ) %>%
    select(-countries, -exempt_countries) %>%
    write_csv('data/processed/chapter99_rates.csv')
  message('Saved Chapter 99 data to data/processed/chapter99_rates.csv')
}
