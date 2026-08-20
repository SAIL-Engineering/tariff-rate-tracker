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

  # --- Country identity comes from the universe, in CENSUS codes -----------
  # These branches used to return ISO codes — c('CN'), c('CA'), 'UK', 'JP',
  # 'EU', 'RU' — while every other branch returned census codes via
  # resolve_country_name(). One column, two code systems. Downstream matches on
  # census codes, so the ISO ones never matched and those headings' scope
  # silently did not apply: 108 such values in 2025_rev_20 alone. 'EU' is not
  # even a country code.
  #
  # A country-scoped EXCEPT clause must be handled BEFORE the universe
  # resolver: the resolver has no notion of negation, so on the 232-style
  # "products of iron or steel ... except products of Australia, of Argentina,
  # ..." it returns the exempt origins as the POSITIVE scope — inverting the
  # steel/aluminum blankets (9903.80.01/.03, 9903.85.01/.03) so the duty
  # applies to exactly the countries the note exempts. Split the except clause
  # off, resolve the REMAINDER for positive scope, and only then let the
  # resolver see the rest of the text.
  except_loc <- str_locate(desc_lower,
    'except[^,]*(products? of|of)\\s+([^,]+(?:,\\s*(?:of\\s+)?[^,]+)*)')
  if (!is.na(except_loc[1, 1])) {
    except_text <- substr(description, except_loc[1, 1], except_loc[1, 2])
    exempt <- extract_country_names(except_text)
    if (length(exempt) > 0) {
      # Strip by position from the original-case text: the resolver's intent
      # pattern keys on proper nouns, so it must see the unlowered remainder.
      remainder <- paste0(substr(description, 1, except_loc[1, 1] - 1),
                          substr(description, except_loc[1, 2] + 1,
                                 nchar(description)))
      rs <- if (exists('resolve_country_scope', mode = 'function')) {
        tryCatch(resolve_country_scope(remainder), error = function(e) NULL)
      } else NULL
      if (!is.null(rs) && rs$outcome == 'country_scoped' &&
          length(rs$census_codes) > 0) {
        return(list(type = 'specific',
                    countries = setdiff(as.character(rs$census_codes), exempt),
                    exempt = exempt))
      }
      return(list(type = 'all_except', countries = character(0),
                  exempt = exempt))
    }
  }

  # resolve_country_scope() answers both questions at once (is this scoped by
  # country, and which) against the maintained 253-name universe, so no country
  # is named in code here.
  if (exists('resolve_country_scope', mode = 'function')) {
    rs <- tryCatch(resolve_country_scope(description), error = function(e) NULL)
    if (!is.null(rs) && rs$outcome == 'country_scoped' && length(rs$census_codes) > 0) {
      return(list(type = 'specific', countries = as.character(rs$census_codes),
                  exempt = character(0)))
    }
  }

  # US Note 31 = Biden Section 301 increases. A NOTE reference, not a country
  # name, so the universe cannot resolve it — this stays explicit, and resolves
  # the origin through the same helper rather than hardcoding a code.
  if (str_detect(desc_lower, 'u\\.s\\.\\s*note\\s*31')) {
    cn <- resolve_country_name('China')
    if (length(cn) > 0) {
      return(list(type = 'specific', countries = as.character(cn),
                  exempt = character(0)))
    }
  }

  # "articles the product of <Country>" is an unambiguous country-specific scope,
  # and it must be tested BEFORE the "except ... heading" blanket branch below.
  #
  # This ordering is load-bearing. The 2026 §301 regimes (note 50 Brazil, note 52
  # forced labor for 60 economies) phrase every per-country rate line as
  #   "Except for products described in headings 9903.05.85-9903.05.92,
  #    articles the product of <Country>, as provided for in U.S. note 52..."
  # which matches `except.*heading`. That branch used to consult a hardcoded
  # 7-country shortlist (canada/mexico/japan/korea/kingdom/european/russia) and,
  # for any country NOT on it, returned type='all' with an EMPTY country list —
  # silently converting a country-specific duty into a blanket all-countries rate
  # and stamping it 'resolved_by_parser' so the Ch99 completeness gate never saw
  # it. In 2026 rev_13 that mis-scoped 53 rated headings (10%/12.5%/25%); only
  # Mexico and Russia tripped the gate, purely because they happened to be ON the
  # shortlist and so fell through to 'unknown'.
  # "articles the product of a member state of the European Union" — a single
  # heading covering all 27 EU census origins (note 52 uses this for the EU tier).
  if (str_detect(desc_lower, 'product of a member state of the european union')) {
    eu <- tryCatch(load_policy_params()$EU27_CODES, error = function(e) NULL)
    if (length(eu) > 0) {
      return(list(type = 'specific', countries = as.character(eu),
                  exempt = character(0)))
    }
    return(list(type = 'unknown', countries = character(0), exempt = character(0)))
  }

  product_of <- str_match(
    description,
    '(?:articles?|goods)\\s+(?:that\\s+are\\s+)?the\\s+product\\s+of\\s+(?:the\\s+)?([A-Z][^,;]*?)\\s*(?:,|;|\\s+that\\s|\\s+as\\s+provided|\\s+which\\s|$)'
  )
  if (!is.na(product_of[1, 1])) {
    codes <- resolve_country_name(product_of[1, 2])
    if (length(codes) > 0) {
      return(list(type = 'specific', countries = codes, exempt = character(0)))
    }
    # Named a country we cannot map to a code. Do NOT fall through to the
    # blanket branch — that is the bug described above. Return 'unknown' so the
    # completeness gate surfaces it if the heading carries a rate.
    return(list(type = 'unknown', countries = character(0), exempt = character(0)))
  }

  # Check for "except" clauses that reference HTS headings, not countries.
  # e.g., "Except for derivative iron or steel products described in headings 9903.81.89..."
  # These are blanket rates — the "except" carves out other HTS codes, not countries.
  if (str_detect(desc_lower, 'except.*(?:heading|subheading|9903)')) {
    # The 7-country shortlist that used to guard this branch is gone. It was the
    # cause the comment above describes: a country NOT on it fell through to a
    # blanket 'all' with an empty country list. The universe resolver now runs
    # FIRST, so any country-scoped description has already returned; reaching
    # here means no known country is named, and 'all' is the correct reading of
    # an "except <heading>" carve-out.
    return(list(type = 'all', countries = character(0), exempt = character(0)))
  }

  # Check for "except products of..." pattern (Section 232 style)
  except_match <- str_match(desc_lower, 'except[^,]*(products? of|of)\\s+([^,]+(?:,\\s*(?:of\\s+)?[^,]+)*)')
  if (!is.na(except_match[1, 1])) {
    # Extract country names from the exception list
    except_text <- except_match[1, 3]
    exempt <- extract_country_names(except_text)
    return(list(type = 'all_except', countries = character(0), exempt = exempt))
  }

  # (Russian Federation is resolved by the universe above — it is an alias row
  #  in resources/country_name_aliases.csv, not a hardcoded branch.)

  # Country-specific "products of [country]" or "[items] of the [country]" pattern
  # (Section 232 deals, wood tariffs)
  # e.g., "Passenger vehicles that are products of the United Kingdom"
  #        "Wood products of Japan as provided for..."
  #        "...products of the European Union..."
  #        "...parts of passenger vehicles and light trucks of the United Kingdom..."
  #        "...products of South Korea..."
  # (United Kingdom / Japan / European Union / Korea are resolved by the
  #  universe above. The old map returned ISO codes into a census-code column,
  #  so its scope never matched downstream.)

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
  # Was a hardcoded 25-country map while resources/census_codes.csv held 241 and
  # country_name_aliases.csv held the spelling variants — so any origin outside
  # those 25 was silently invisible, and the codes returned were ISO into a
  # census-code column. Delegates to the shared universe resolver, which also
  # handles parenthetical census names, diacritics and blocs.
  if (!exists('find_countries_in_text', mode = 'function')) return(character(0))
  hits <- tryCatch(find_countries_in_text(text), error = function(e) NULL)
  if (is.null(hits) || nrow(hits) == 0) return(character(0))
  unique(as.character(unlist(hits$census_codes)))
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
    # §201 claims come FIRST, before the generic country-scope arm: "who applies
    # this duty" is orthogonal to "did the country scope parse". Quartz
    # (9903.45.30/.31) parses country_type='all' from "product of any country",
    # which used to stamp resolved_by_parser and let a brand-new rated safeguard
    # sail past the completeness gate with no modelling path at all.
    #
    # Section 201 SOLAR safeguard (CSPV cells/modules, 9903.45.21-.29) — MODELED
    # by extract_section_201_rates() from resources/s201_solar_products.csv.
    grepl('^9903\\.45\\.2[1-9]', ch99_code) ~ 'handled_by_s201_extractor',
    # Section 201 QUARTZ surface products TRQ (9903.45.30 in-quota 25% /
    # 9903.45.31 over-quota 50%; U.S. note 41, 91 FR 50645, quota periods from
    # 2026-08-15). The actual rate depends on quota standing — a fact we do not
    # hold — so NO rate is collapsed into rate_section_201. Emitted as a
    # requires-more-facts determination (both tiers, note-41(c) exemptions) in
    # ch99_rules_json via build_s201_quartz_candidates().
    grepl('^9903\\.45\\.3[01]', ch99_code) ~ 'handled_by_s201_determination',
    country_type != 'unknown' ~ 'resolved_by_parser',
    # Section 338 Canada (19 U.S.C. 1338; Proclamation 11047 and siblings of
    # 2026-07-20, eff. 2026-08-19). PREDICTED headings 9903.03.12-.14 — §122's
    # 9903.03.01-.11 expired 2026-07-23, freeing the range. Handled by the
    # section_338 config block.
    grepl('^9903\\.03\\.1[2-9]$', ch99_code) ~ 'handled_by_s338_config',
    # Section 122 (post-IEEPA blanket authority): 9903.03.01-.11
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
    # Section 301 Brazil (U.S. note 50, 91 FR 45516, eff. 2026-07-22):
    # 9903.05.01 carries the +25% rate; .02-.09 are the in-transit window,
    # subdivision carve-outs, civil aircraft, pharma, donations and
    # informational materials — exclusions with no additional duty.
    # Handled by the section_301_brazil config in policy_params.yaml.
    grepl('^9903\\.05\\.01$', ch99_code) ~ 'handled_by_s301br_config',
    grepl('^9903\\.05\\.0[2-9]$', ch99_code) ~ 's301br_exclusion_no_rate',
    # Section 301 forced labor, 60 economies (U.S. note 52, 91 FR 47318 /
    # 91 FR 47717, eff. 2026-07-24): 9903.05.20-.84 are the per-economy rate
    # lines (10% / 12.5%, flat or total-duty-capped); 9903.05.85-.99 and
    # 9903.06.01-.21 are the note 52(b)-(k) exclusions, the in-transit window
    # and the per-country carve-outs — no additional duty of their own.
    # Handled by the section_301_forced_labor config in policy_params.yaml.
    grepl('^9903\\.05\\.[2-7][0-9]$', ch99_code) ~ 'handled_by_s301fl_config',
    grepl('^9903\\.05\\.8[0-4]$', ch99_code) ~ 'handled_by_s301fl_config',
    grepl('^9903\\.05\\.(8[5-9]|9[0-9])$', ch99_code) ~ 's301fl_exclusion_no_rate',
    grepl('^9903\\.06\\.', ch99_code) ~ 's301fl_exclusion_no_rate',
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
    # (Solar 9903.45.2x and quartz 9903.45.3x are claimed at the TOP of this
    #  case_when, above the country-scope arm.)
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
# Hierarchical country scope. Sourced here rather than relying on the caller,
# because tests and scripts source this file directly.
if (!exists('resolve_country_scope_hierarchical', mode = 'function')) {
  try(source(here::here('src', 'resolve_country_scope.R')), silent = TRUE)
}

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

  # --- Country scope carried by UNNUMBERED PARENT lines --------------------
  # The tariff schedule is a tree, and the filter above keeps only the leaves.
  # An unnumbered parent states the origin while the numbered child states the
  # rate:
  #
  #   (no htsno) indent 0   "Articles the product of Japan:"
  #   9903.41.15 indent 1   "Automatic data processing machines..."     100%
  #
  # Dropping the parent makes the child look scope-less, which is why §201
  # reported 18 of 20 headings unresolved. Measured on 2025_rev_20: 254 headings
  # are scoped by their own text and a further 262 ONLY through a parent — 42% of
  # the chapter, silently lost.
  #
  # So walk the CONTIGUOUS slice of the raw schedule that spans Chapter 99,
  # unnumbered lines included, and resolve scope down the indent hierarchy.
  .idx <- which(vapply(hts_raw, function(x) grepl('^9903\\.', x$htsno %||% ''), logical(1)))
  scope_by_code <- NULL
  if (length(.idx) > 0 && exists('resolve_country_scope_hierarchical', mode = 'function')) {
    slice <- hts_raw[min(.idx):max(.idx)]
    stbl <- tibble(
      htsno       = vapply(slice, function(x) x$htsno %||% '', character(1)),
      indent      = suppressWarnings(as.integer(vapply(slice, function(x)
                      as.character(x$indent %||% NA), character(1)))),
      description = vapply(slice, function(x) x$description %||% '', character(1)))
    stbl <- tryCatch(resolve_country_scope_hierarchical(stbl),
                     error = function(e) { message('  [scope hierarchy skipped: ',
                                                   conditionMessage(e), ']'); NULL })
    if (!is.null(stbl)) {
      scope_by_code <- stbl %>%
        filter(nzchar(htsno)) %>%
        select(ch99_code = htsno, scope_outcome = outcome,
               scope_source, scope_codes = census_codes,
               scope_names = country_names)
      n_inh <- sum(scope_by_code$scope_source == 'inherited', na.rm = TRUE)
      message('  Country scope via parent-line inheritance: ', n_inh, ' heading(s)')
    }
  }

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

  # --- Apply the hierarchy-resolved scope, MONOTONICALLY ------------------
  # Only where the flat parser found nothing and the hierarchy found countries.
  # Deliberately one-directional:
  #
  #   unknown + countries found  ->  'specific'   RECOVERS duty that was dropped
  #   not_country_scoped         ->  left 'unknown', still fail-closed
  #
  # Mapping not_country_scoped to 'all' would be the larger, correct-sounding
  # change and is exactly the one to make separately: it turns a dropped duty
  # into a globally applied one, and several such headings carry 100% rates.
  # Recovering scope and blanket-applying are different risks; only the first
  # is taken here.
  parsed$scope_outcome <- NA_character_
  parsed$scope_source  <- NA_character_
  if (!is.null(scope_by_code)) {
    m <- match(parsed$ch99_code, scope_by_code$ch99_code)
    parsed$scope_outcome <- scope_by_code$scope_outcome[m]
    parsed$scope_source  <- scope_by_code$scope_source[m]
    # "Articles the product of any country ..." is an explicit ALL-origins
    # provision. The resolver marks it country_scoped with an EMPTY code list,
    # meaning "every origin" — distinct from an empty list because nothing was
    # found. Leaving it 'unknown' fails it closed, dropping a duty the schedule
    # states applies universally.
    any_country <- which(!is.na(m) & parsed$country_type == 'unknown' &
                         parsed$scope_outcome == 'country_scoped' &
                         lengths(scope_by_code$scope_codes[m]) == 0)
    if (length(any_country) > 0) {
      parsed$country_type[any_country] <- 'all'
      message('  Scope: ', length(any_country),
              ' heading(s) state "any country" -> all origins')
    }

    upgrade <- which(!is.na(m) & parsed$country_type == 'unknown' &
                     parsed$scope_outcome == 'country_scoped' &
                     lengths(scope_by_code$scope_codes[m]) > 0)
    if (length(upgrade) > 0) {
      for (k in upgrade) {
        parsed$countries[[k]]  <- scope_by_code$scope_codes[[m[k]]]
        parsed$country_type[k] <- 'specific'
      }
      rated <- sum(!is.na(parsed$rate[upgrade]) & parsed$rate[upgrade] > 0)
      message('  Scope recovered from hierarchy for ', length(upgrade),
              ' heading(s) previously unresolved (', rated, ' carrying a rate)')
    }
  }

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

  # §201 safeguard ranges: a RATED heading whose only claim is the generic
  # country-scope parse has NO modelling path — nothing applies its duty and no
  # determination discloses it. This is exactly how quartz (9903.45.30/.31,
  # new in 2026_rev_16) landed at 0% with no gate firing: "product of any
  # country" parsed to country_type='all' -> resolved_by_parser, and the
  # unresolved-rated check above never saw it. Every rated §201-range heading
  # must be claimed by a §201 status (extractor / determination / TRQ) or go
  # through the unresolved path above and its allowlist.
  s201_claimed <- c('handled_by_s201_extractor', 'handled_by_s201_determination',
                    'not_duty_relevant_trq', 'unresolved_s201', 'unresolved')
  s201_unclaimed_rated <- ch99_data %>%
    filter(grepl('^9903\\.(40|41|45|46|47)', ch99_code),
           !is.na(rate), rate > 0,
           !resolution_status %in% s201_claimed)
  unresolved_rated <- bind_rows(unresolved_rated, s201_unclaimed_rated)

  # Defense in depth against the mis-scoping class of bug: a heading whose text
  # names a specific origin ("articles the product of Kazakhstan") but which the
  # parser scoped to country_type = 'all' with an EMPTY country list is a
  # country-specific duty silently promoted to a global blanket rate. That
  # promotion stamps resolution_status = 'resolved_by_parser', so the
  # unresolved-rated check above can never see it — which is exactly how 53 rated
  # headings of the 2026 note-52 regime passed this gate while only 2 tripped it.
  # Needs the scope columns; tolerate reduced fixtures/older caches without them.
  mis_scoped <- if (all(c('country_type', 'countries', 'description') %in% names(ch99_data))) {
    ch99_data %>%
      filter(!is.na(rate), rate > 0, country_type == 'all',
             lengths(countries) == 0,
             grepl('the product of\\s+(?:the\\s+)?[A-Z]', coalesce(description, ''))) %>%
      filter(!ch99_code %in% (
        if (file.exists(here('config', 'ch99_unresolved_allowlist.csv'))) {
          readr::read_csv(here('config', 'ch99_unresolved_allowlist.csv'),
                          col_types = readr::cols(.default = readr::col_character()))$ch99_code
        } else character(0)))
  } else {
    ch99_data[0, , drop = FALSE]
  }
  if (nrow(mis_scoped) > 0) {
    msg <- paste0(
      'Chapter 99 country scope: ', nrow(mis_scoped), ' rated heading(s) name a ',
      'specific origin but were scoped to ALL countries with an empty country ',
      'list — a country-specific duty promoted to a global blanket rate: ',
      paste(utils::head(mis_scoped$ch99_code, 10), collapse = ', '),
      if (nrow(mis_scoped) > 10) ' ...' else '',
      '. Fix parse_countries() (or resolve_country_name() for the origin name).'
    )
    rev_year_ms <- suppressWarnings(as.integer(substr(revision_id %||% '', 1, 4)))
    if (!identical(Sys.getenv('SAIL_CH99_STRICT', '1'), '0') &&
        !is.na(rev_year_ms) && rev_year_ms >= 2025) stop(msg) else warning(msg)
  }

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
