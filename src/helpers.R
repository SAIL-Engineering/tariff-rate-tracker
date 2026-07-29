# =============================================================================
# Helper Functions for Tariff Rate Tracker
# =============================================================================

library(tidyverse)
library(jsonlite)
library(yaml)
library(here)

# =============================================================================
# Rate Parsing Functions
# =============================================================================

#' Parse a rate string from HTS into numeric value
#'
#' Handles formats:
#'   - "6.8%" -> 0.068
#'   - "Free" -> 0.0
#'   - "" or NA -> NA
#'   - Compound rates (e.g., "2.4¢/kg + 5%") -> NA with flag
#'   - Specific rates (e.g., "$1.50/doz") -> NA with flag
#'
#' @param rate_string Character string containing rate
#' @return Numeric rate or NA
parse_rate <- function(rate_string) {
  if (is.null(rate_string) || is.na(rate_string) || rate_string == '') {
    return(NA_real_)
  }

  # Trim whitespace
  rate_string <- trimws(rate_string)

  # Handle "Free"
  if (tolower(rate_string) == 'free') {
    return(0.0)
  }

  # Simple percentage: "6.8%" or "25%"
  if (grepl('^[0-9.]+%$', rate_string)) {
    value <- as.numeric(gsub('%', '', rate_string))
    return(value / 100)
  }

  # Percentage with decimals but no % sign (rare, treat as fraction e.g. 0.25 = 25%)
  if (grepl('^[0-9]+\\.[0-9]+$', rate_string) && as.numeric(rate_string) < 1) {
    warning('parse_rate: interpreting "', rate_string, '" as fraction (not percentage). ',
            'Add % suffix to rate strings for clarity.')
    return(as.numeric(rate_string))
  }

  # Compound or specific rates - return NA (need manual handling)
  return(NA_real_)
}

#' Check if a rate string is a simple ad valorem rate
#'
#' @param rate_string Character string
#' @return Logical TRUE if simple ad valorem
is_simple_rate <- function(rate_string) {
  if (is.null(rate_string) || is.na(rate_string) || rate_string == '') {
    return(FALSE)
  }
  rate_string <- trimws(rate_string)
  tolower(rate_string) == 'free' || grepl('^[0-9.]+%$', rate_string)
}


# =============================================================================
# HTS Code Functions
# =============================================================================

#' Normalize HTS code to 10-digit format
#'
#' Removes periods/dots and pads to 10 digits.
#' Returns NA for codes that are too short (<4 digits) or too long (>10 digits).
#'
#' @param hts_code Character HTS code (e.g., "0101.30.00.00")
#' @return Character 10-digit code (e.g., "0101300000")
normalize_hts <- function(hts_code) {
  if (is.null(hts_code) || is.na(hts_code) || hts_code == '') {
    return(NA_character_)
  }
  # Remove periods
  clean <- gsub('\\.', '', hts_code)
  # Guard: must be 4-10 digits

  if (nchar(clean) < 4 || nchar(clean) > 10) {
    return(NA_character_)
  }
  # Pad to 10 digits if needed
  if (nchar(clean) < 10) {
    clean <- str_pad(clean, 10, side = 'right', pad = '0')
  }
  return(clean)
}

#' Sanitize a statistical reporting unit from the HTS source.
#'
#' USITC's HTS export inconsistently encodes some reporting units with HTML
#' markup while encoding the SAME unit as plain ASCII in other revisions, e.g.
#' "m<sup>2</sup>" vs "m2", "Cr<sub>2</sub>O<sub>3</sub> t" vs "Cr2O3 t",
#' "<u>kg</u>" vs "kg", "<il>doz. prs.</il>" vs "doz. prs.", "doz.&nbsp;" vs
#' "doz.". This canonicalizes every form to plain ASCII so a unit is identical
#' across revisions: tags are dropped (inner text kept), entities decoded,
#' whitespace collapsed. Display-side prettifying (m2 -> m^2) lives in the
#' frontend, not here.
#'
#' Only values that actually carry markup/entities are touched; plain values
#' (including pre-existing whitespace quirks like a trailing space in "No. ")
#' are returned byte-for-byte. This keeps the transform scoped to the USITC
#' markup inconsistency — so the one-off parquet backfill rewrites only the ~20
#' affected revisions, and a fresh build produces identical output.
#'
#' @param x Character vector of raw reporting units (NA-safe, vectorized).
#' @return Character vector with HTML markup stripped to plain ASCII.
clean_reported_unit <- function(x) {
  if (is.null(x)) return(x)
  out <- as.character(x)
  dirty <- !is.na(out) & grepl('<[^>]*>|&[a-z]+;', out, perl = TRUE)
  if (!any(dirty)) return(out)
  v <- out[dirty]
  # Drop any HTML tag but keep its inner text. Handles <sup>/<sub>/<u>/<il>
  # and tags carrying inline styles, e.g. <sup style="font-size: 9.75px;">.
  v <- gsub('<[^>]*>', '', v, perl = TRUE)
  # Decode the handful of entities the source uses.
  v <- gsub('&nbsp;', ' ', v, fixed = TRUE)
  v <- gsub('&amp;', '&', v, fixed = TRUE)
  # Collapse internal whitespace (incl. stray newlines) and trim.
  v <- trimws(gsub('\\s+', ' ', v, perl = TRUE))
  out[dirty] <- v
  out
}

#' Extract prefix at specified digit level
#'
#' @param hts10 10-digit HTS code
#' @param digits Number of digits (2, 4, 6, 8, or 10)
#' @return Character prefix
hts_prefix <- function(hts10, digits) {
  substr(hts10, 1, digits)
}


# =============================================================================
# Footnote Parsing Functions
# =============================================================================

#' Extract Chapter 99 references from footnotes
#'
#' Looks for references like "See 9903.88.15" in footnotes
#'
#' @param footnotes List of footnote objects from HTS JSON
#' @return Character vector of Chapter 99 subheadings
extract_chapter99_refs <- function(footnotes) {
  if (is.null(footnotes) || length(footnotes) == 0) {
    return(character(0))
  }

  refs <- character(0)

  for (fn in footnotes) {
    if (!is.null(fn$value)) {
      # Pattern: 9903.XX.XX (Chapter 99 subchapter III only)
      matches <- str_extract_all(fn$value, '9903\\.[0-9]{2}\\.[0-9]{2}')[[1]]
      refs <- c(refs, matches)
    }
  }

  return(unique(refs))
}


# =============================================================================
# Special Program Parsing
# =============================================================================

#' Parse special rate programs from the special column
#'
#' The special column contains text like:
#' "Free (A+,AU,BH,CL,CO,D,E,IL,JO,KR,MA,OM,P,PA,PE,S,SG)"
#'
#' @param special_string Character string from special column
#' @return List with rate and programs
parse_special_programs <- function(special_string) {
  if (is.null(special_string) || is.na(special_string) || special_string == '') {
    return(list(rate = NA_real_, programs = character(0)))
  }

  # Extract rate (before parentheses)
  rate_match <- str_extract(special_string, '^[^(]+')
  rate <- if (!is.na(rate_match)) parse_rate(trimws(rate_match)) else NA_real_

  # Extract program codes from parentheses
  programs_match <- str_extract(special_string, '\\(([^)]+)\\)')
  programs <- if (!is.na(programs_match)) {
    codes <- gsub('[()]', '', programs_match)
    trimws(unlist(strsplit(codes, ',')))
  } else {
    character(0)
  }

  return(list(rate = rate, programs = programs))
}


#' Parse a rate string into a structured representation
#'
#' Unlike parse_rate() which returns a single numeric (or NA for complex rates),
#' this function returns a structured list describing the full rate, including
#' specific and compound duties.
#'
#' Supported formats:
#'   "Free"                    -> type = "free"
#'   "6.8%"                    -> type = "ad_valorem"
#'   "1\u00a2/kg"              -> type = "specific"
#'   "$1.104/kg"               -> type = "specific"
#'   "$1.104/kg + 14.9%"       -> type = "compound"
#'   "46.3\u00a2/kg + 14.9%"   -> type = "compound"
#'   "68\u00a2/head"           -> type = "specific"
#'
#' @param rate_string Character string containing rate
#' @return List with: type, ad_valorem_pct, specific_amount, specific_rate_unit, raw
parse_rate_extended <- function(rate_string) {
  empty_result <- list(
    type = 'unknown', ad_valorem_pct = NA_real_,
    specific_amount = NA_real_, specific_rate_unit = NA_character_, raw = ''
  )

  if (is.null(rate_string) || is.na(rate_string) || trimws(rate_string) == '') {
    return(empty_result)
  }

  raw <- trimws(rate_string)
  # Normalize whitespace (HTS data sometimes has extra spaces)
  clean <- gsub('\\s+', ' ', raw)

  # Free
  if (tolower(clean) == 'free') {
    return(list(
      type = 'free', ad_valorem_pct = 0.0,
      specific_amount = NA_real_, specific_rate_unit = NA_character_, raw = raw
    ))
  }

  # Simple ad valorem: "6.8%" or "25%"
  if (grepl('^[0-9.]+%$', clean)) {
    pct <- as.numeric(gsub('%', '', clean)) / 100
    return(list(
      type = 'ad_valorem', ad_valorem_pct = pct,
      specific_amount = NA_real_, specific_rate_unit = NA_character_, raw = raw
    ))
  }

  # Compound: specific + ad valorem
  # Patterns: "$1.104/kg + 14.9%", "46.3¢/kg + 14.9%", "1¢/kg + 5%"
  compound_match <- regmatches(clean, regexec(
    '^\\$?([0-9.]+)(\u00a2)?/([A-Za-z0-9.]+)\\s*\\+\\s*([0-9.]+)%$', clean
  ))[[1]]
  if (length(compound_match) == 5) {
    amount <- as.numeric(compound_match[2])
    is_cents <- compound_match[3] == '\u00a2'
    unit <- compound_match[4]
    av_pct <- as.numeric(compound_match[5]) / 100
    # If ¢ sign present, convert cents to dollars; if $ prefix, already dollars
    if (is_cents) amount <- amount / 100
    return(list(
      type = 'compound', ad_valorem_pct = av_pct,
      specific_amount = amount, specific_rate_unit = unit, raw = raw
    ))
  }

  # Specific only: "1¢/kg", "$3/head", "4.4¢/kg", "$1.50/doz"
  specific_match <- regmatches(clean, regexec(
    '^\\$?([0-9.]+)(\u00a2)?/([A-Za-z0-9.]+)$', clean
  ))[[1]]
  if (length(specific_match) == 4) {
    amount <- as.numeric(specific_match[2])
    is_cents <- specific_match[3] == '\u00a2'
    unit <- specific_match[4]
    if (is_cents) amount <- amount / 100
    return(list(
      type = 'specific', ad_valorem_pct = NA_real_,
      specific_amount = amount, specific_rate_unit = unit, raw = raw
    ))
  }

  # Unrecognized format
  empty_result$raw <- raw
  return(empty_result)
}


#' Parse the special column into multiple sub-rate groups
#'
#' The special column can contain multiple rate groups, e.g.:
#'   "Free (BH,CL,JO,...) 1.7% (KR) See 9822.04.01 (AU)"
#'
#' Each group has a rate (or "See" reference) followed by country/program codes
#' in parentheses.
#'
#' @param special_string Character string from the special column
#' @return List of lists, each with: rate (numeric|NA), rate_raw (char),
#'         programs (char vector), entry_type ("rate"|"reference")
parse_special_programs_multi <- function(special_string) {
  if (is.null(special_string) || is.na(special_string) || trimws(special_string) == '') {
    return(list())
  }

  s <- trimws(special_string)
  # Normalize whitespace
  s <- gsub('\\s+', ' ', s)

  # Strategy: find all parenthesized groups and the text preceding each one.
  # Pattern: capture everything up to and including each (...) group.
  # Use gregexpr to find all "(<codes>)" positions, then split around them.
  paren_locs <- gregexpr('\\([^)]+\\)', s)[[1]]
  if (paren_locs[1] == -1) {
    # No parentheses — treat entire string as a single rate with no programs
    parsed <- parse_rate_extended(s)
    return(list(list(
      rate = parsed$ad_valorem_pct %||% parsed$specific_amount,
      rate_raw = s,
      programs = character(0),
      entry_type = 'rate',
      parsed = parsed
    )))
  }

  paren_lengths <- attr(paren_locs, 'match.length')
  results <- list()
  prev_end <- 1

  for (i in seq_along(paren_locs)) {
    paren_start <- paren_locs[i]
    paren_end <- paren_start + paren_lengths[i] - 1

    # Text before this parenthesized group (the rate part)
    rate_text <- trimws(substr(s, prev_end, paren_start - 1))

    # Codes inside parentheses
    codes_text <- substr(s, paren_start + 1, paren_end - 1)
    programs <- trimws(unlist(strsplit(codes_text, ',')))

    # Determine entry type
    is_reference <- grepl('^See\\b', rate_text, ignore.case = TRUE)

    if (is_reference) {
      results[[length(results) + 1]] <- list(
        rate = NA_real_,
        rate_raw = rate_text,
        programs = programs,
        entry_type = 'reference',
        parsed = list(type = 'reference', ad_valorem_pct = NA_real_,
                      specific_amount = NA_real_, specific_rate_unit = NA_character_,
                      raw = rate_text)
      )
    } else {
      parsed <- parse_rate_extended(rate_text)
      rate_val <- if (parsed$type == 'free') 0.0
                  else if (!is.na(parsed$ad_valorem_pct)) parsed$ad_valorem_pct
                  else parsed$specific_amount
      results[[length(results) + 1]] <- list(
        rate = rate_val,
        rate_raw = rate_text,
        programs = programs,
        entry_type = 'rate',
        parsed = parsed
      )
    }

    prev_end <- paren_end + 1
  }

  return(results)
}


#' Classify a rate string's basis
#'
#' @param rate_string Character string
#' @return One of "ad_valorem", "specific", "compound", "free", "unknown"
rate_type_label <- function(rate_string) {
  if (is.null(rate_string) || is.na(rate_string) || trimws(rate_string) == '') {
    return('unknown')
  }
  parsed <- parse_rate_extended(rate_string)
  return(parsed$type)
}


#' Determine 19 CFR 159.3 rounding rule for a parsed rate
#'
#' Per 19 CFR 159.3:
#'   - Ad valorem: value rounded to even dollars (fractions <$0.50
#'     disregarded, >=$0.50 treated as $1).
#'   - Specific rate <= $1/unit: fractional qty <0.5 disregarded,
#'     >=0.5 treated as whole unit.
#'   - Specific rate > $1/unit: duty on exact qty, fraction to 2 decimals.
#'   - Compound: both rules apply to their respective components.
#'
#' @param parsed Result from parse_rate_extended()
#' @return Character: rounding rule code
determine_rounding_rule <- function(parsed) {
  if (parsed$type %in% c('free', 'ad_valorem')) {
    return('19cfr159.3_value')
  }
  if (parsed$type == 'specific') {
    if (!is.na(parsed$specific_amount) && parsed$specific_amount > 1.0) {
      return('19cfr159.3_specific_gt1')
    }
    return('19cfr159.3_specific_lte1')
  }
  if (parsed$type == 'compound') {
    # Compound has both: the specific component's rule depends on amount
    if (!is.na(parsed$specific_amount) && parsed$specific_amount > 1.0) {
      return('19cfr159.3_compound_gt1')
    }
    return('19cfr159.3_compound_lte1')
  }
  return('unknown')
}


# =============================================================================
# Country Code Functions
# =============================================================================

#' Load census country codes
#'
#' @return Tibble with Code and Name columns
load_census_codes <- function(path = here('resources', 'census_codes.csv')) {
  read_csv(
    path,
    col_types = cols(Code = col_character(), Name = col_character())
  )
}

#' Load country to partner mapping
#'
#' @return Tibble with cty_code, cty_name, partner columns
load_country_partner_mapping <- function(path = here('resources', 'country_partner_mapping.csv')) {
  read_csv(
    path,
    col_types = cols(.default = col_character())
  )
}

#' Get all country codes from census_codes.csv
#'
#' @return Character vector of all country codes
get_all_country_codes <- function() {
  census <- load_census_codes()
  census$Code
}


# =============================================================================
# ISO Country Metadata
# =============================================================================

#' Load ISO 3166-1 country metadata
#'
#' Reads the local JSON file with ISO alpha-2/alpha-3 codes for all countries.
#'
#' @param path Path to the ISO JSON file
#' @return Tibble with columns: iso_name, alpha2, alpha3
load_iso_countries <- function(path = here('data', 'countries-ISO-3166-1-alpha-2.json')) {
  if (!file.exists(path)) {
    stop('ISO country file not found: ', path,
         '\nExpected at data/countries-ISO-3166-1-alpha-2.json')
  }
  raw <- jsonlite::fromJSON(path, simplifyDataFrame = TRUE)
  tibble::as_tibble(raw) %>%
    select(iso_name = country, alpha2, alpha3)
}

#' Normalize a country name for fuzzy matching
#'
#' Lowercases, trims whitespace, removes non-alphanumeric characters
#' (except spaces), and collapses multiple spaces.
#'
#' @param x Character vector of country names
#' @return Normalized character vector
normalize_country_name <- function(x) {
  x <- tolower(trimws(x))
  x <- gsub('[^a-z0-9 ]', '', x)
  x <- gsub('\\s+', ' ', x)
  x
}

# Manual mapping for Census country names that don't match ISO names directly.
# Keys are normalized Census names; values are ISO alpha-2 codes.
MANUAL_ISO_MAP <- c(
  'korea, south'                            = 'KR',
  'korea, north'                            = 'KP',
  'korea south'                             = 'KR',
  'korea north'                             = 'KP',
  'republic of korea'                       = 'KR',
  'democratic peoples republic of korea'    = 'KP',
  'taiwan'                                  = 'TW',
  'russia'                                  = 'RU',
  'russian federation'                      = 'RU',
  'vietnam'                                 = 'VN',
  'viet nam'                                = 'VN',
  'iran'                                    = 'IR',
  'iran islamic republic of'                = 'IR',
  'syria'                                   = 'SY',
  'syrian arab republic'                    = 'SY',
  'venezuela'                               = 'VE',
  'venezuela bolivarian republic of'        = 'VE',
  'bolivia'                                 = 'BO',
  'bolivia plurinational state of'          = 'BO',
  'united kingdom'                          = 'GB',
  'united states of america'                = 'US',
  'czech republic'                          = 'CZ',
  'czechia'                                 = 'CZ',
  'ivory coast'                             = 'CI',
  'cote divoire'                            = 'CI',
  'congo democratic republic of the'        = 'CD',
  'congo republic of the'                   = 'CG',
  'congo kinshasa'                          = 'CD',
  'congo brazzaville'                       = 'CG',
  'tanzania'                                = 'TZ',
  'tanzania united republic of'             = 'TZ',
  'laos'                                    = 'LA',
  'lao peoples democratic republic'         = 'LA',
  'brunei'                                  = 'BN',
  'brunei darussalam'                       = 'BN',
  'macau'                                   = 'MO',
  'macao'                                   = 'MO',
  'hong kong'                               = 'HK',
  'eswatini'                                = 'SZ',
  'swaziland'                               = 'SZ',
  'myanmar'                                 = 'MM',
  'burma'                                   = 'MM',
  'palestine'                               = 'PS',
  'palestine state of'                      = 'PS',
  'vatican city'                            = 'VA',
  'holy see'                                = 'VA',
  'micronesia'                              = 'FM',
  'micronesia federated states of'          = 'FM',
  'moldova'                                 = 'MD',
  'moldova republic of'                     = 'MD',
  'east timor'                              = 'TL',
  'timorleste'                              = 'TL',
  'cape verde'                              = 'CV',
  'cabo verde'                              = 'CV',
  'macedonia'                               = 'MK',
  'north macedonia'                         = 'MK',
  'dominican republic'                      = 'DO',
  'british virgin islands'                  = 'VG',
  'curacao'                                 = 'CW',
  'denmark except greenland'                = 'DK',
  'denmark'                                 = 'DK',
  'moldova republic of moldova'             = 'MD',
  'holy see vatican city'                   = 'VA',
  'kosovo'                                  = 'XK',
  'laos lao peoples democratic republic'    = 'LA',
  'north korea democratic peoples republic of korea' = 'KP',
  'south korea republic of korea'           = 'KR',
  'christmas island in the indian ocean'    = 'CX',
  'christmas island'                        = 'CX',
  'sudan'                                   = 'SD',
  'niger'                                   = 'NE',
  'congo republic of the congo'             = 'CG',
  'congo democratic republic of the congo formerly za' = 'CD',
  'british indian ocean territory'          = 'IO',
  'reunion'                                 = 'RE',
  'french southern and antarctic lands'     = 'TF',
  'virgin islands of the united states'     = 'VI'
)

#' Match Census country names to ISO alpha-2/alpha-3 codes
#'
#' Uses a three-pass strategy:
#'   1. Direct match on normalized names
#'   2. Manual mapping for known mismatches
#'   3. Single-hit bidirectional substring match
#'
#' @param census_df Data frame with a 'name' column (Census country names)
#' @param iso_df Tibble from load_iso_countries() (default: loads from disk)
#' @param manual_map Named character vector (normalized name -> alpha2)
#' @return The input data frame with alpha2 and alpha3 columns appended
match_census_to_iso <- function(census_df,
                                iso_df = load_iso_countries(),
                                manual_map = MANUAL_ISO_MAP) {
  iso_lookup <- iso_df %>%
    mutate(norm_name = normalize_country_name(iso_name)) %>%
    select(norm_name, alpha2, alpha3)

  census_df$alpha2 <- NA_character_
  census_df$alpha3 <- NA_character_

  for (i in seq_len(nrow(census_df))) {
    cname <- normalize_country_name(census_df$name[i])

    # Pass 1: direct match
    idx <- match(cname, iso_lookup$norm_name)
    if (!is.na(idx)) {
      census_df$alpha2[i] <- iso_lookup$alpha2[idx]
      census_df$alpha3[i] <- iso_lookup$alpha3[idx]
      next
    }

    # Pass 2: manual map
    if (cname %in% names(manual_map)) {
      a2 <- manual_map[[cname]]
      idx2 <- match(a2, iso_df$alpha2)
      if (!is.na(idx2)) {
        census_df$alpha2[i] <- iso_df$alpha2[idx2]
        census_df$alpha3[i] <- iso_df$alpha3[idx2]
      } else {
        # Code not in ISO file (e.g., XK for Kosovo) — assign alpha2 anyway
        census_df$alpha2[i] <- a2
      }
      next
    }

    # Pass 3: single-hit substring match (bidirectional)
    partial <- which(
      grepl(cname, iso_lookup$norm_name, fixed = TRUE) |
      sapply(iso_lookup$norm_name, function(n) grepl(n, cname, fixed = TRUE))
    )
    if (length(partial) == 1) {
      census_df$alpha2[i] <- iso_lookup$alpha2[partial]
      census_df$alpha3[i] <- iso_lookup$alpha3[partial]
    }
  }

  census_df
}

#' Build comprehensive ISO alpha-2 to Census code mapping
#'
#' Produces a named character vector covering ALL countries with a match,
#' not just the handful hardcoded in policy_params.yaml.
#'
#' @param census_path Path to census_codes.csv
#' @param iso_path Path to ISO JSON file
#' @return Named character vector: names = alpha2 codes, values = Census codes
build_full_iso_census_map <- function(census_path = here('resources', 'census_codes.csv'),
                                      iso_path = here('data', 'countries-ISO-3166-1-alpha-2.json')) {
  census <- load_census_codes(census_path)
  iso <- load_iso_countries(iso_path)
  matched <- match_census_to_iso(
    census %>% rename(name = Name, code = Code),
    iso
  )
  matched <- matched %>% filter(!is.na(alpha2))
  setNames(matched$code, matched$alpha2)
}


# =============================================================================
# Parquet Dataset Helpers
# =============================================================================

#' Open the partitioned rate timeseries Parquet dataset
#'
#' Centralized loader that validates the path and returns an Arrow Dataset.
#' Requires the arrow package to be installed.
#'
#' @param parquet_path Path to the partitioned Parquet directory
#' @param partitioning Partitioning column name(s)
#' @return Arrow Dataset object
open_rate_timeseries <- function(parquet_path = here('data', 'timeseries', 'rate_timeseries_parquet'),
                                 partitioning = 'revision') {
  if (!requireNamespace('arrow', quietly = TRUE)) {
    stop('Package "arrow" is required. Install with: install.packages("arrow")')
  }
  if (!dir.exists(parquet_path)) {
    stop('Parquet dataset not found: ', parquet_path,
         '\nRun: Rscript scripts/combine_snapshots.R')
  }
  ds <- arrow::open_dataset(parquet_path, partitioning = partitioning)
  message('Opened Parquet dataset: ', parquet_path)
  ds
}

#' Query the rate timeseries with optional filters
#'
#' Returns a lazy Arrow query (call collect() to materialize).
#' All filter parameters are optional — NULL means no filter (full dataset).
#'
#' @param ds Arrow Dataset from open_rate_timeseries()
#' @param countries Character vector of Census country codes (NULL = all)
#' @param hts_codes Character vector of 10-digit HTS codes (NULL = all)
#' @param revisions Character vector of revision names (NULL = all)
#' @param date_range Length-2 Date vector for interval overlap (NULL = all)
#' @return Lazy Arrow query (not yet collected)
query_rates <- function(ds, countries = NULL, hts_codes = NULL,
                        revisions = NULL, date_range = NULL) {
  q <- ds
  if (!is.null(revisions)) {
    q <- q %>% filter(revision %in% revisions)
  }
  if (!is.null(countries)) {
    q <- q %>% filter(country %in% countries)
  }
  if (!is.null(hts_codes)) {
    q <- q %>% filter(hts10 %in% hts_codes)
  }
  if (!is.null(date_range)) {
    q <- q %>% filter(valid_from <= date_range[2], valid_until >= date_range[1])
  }
  q
}

#' Get all distinct HTS codes in the dataset
#'
#' @param ds Arrow Dataset
#' @return Character vector of all HTS10 codes
get_all_hts_codes <- function(ds) {
  ds %>%
    distinct(hts10) %>%
    collect() %>%
    pull(hts10) %>%
    sort()
}

#' Get all distinct country codes in the dataset
#'
#' @param ds Arrow Dataset
#' @return Character vector of all Census country codes
get_all_country_codes_from_ds <- function(ds) {
  ds %>%
    distinct(country) %>%
    collect() %>%
    pull(country) %>%
    sort()
}

#' Validate that an HTS column contains properly formatted 10-digit codes
#'
#' @param df Data frame to validate
#' @param col Name of the HTS column
#' @return TRUE (invisibly) if all valid, FALSE with warning if not
validate_hts_column <- function(df, col = 'hts10') {
  vals <- df[[col]]
  bad <- vals[!grepl('^[0-9]{10}$', vals) & !is.na(vals)]
  if (length(bad) > 0) {
    warning('Found ', length(bad), ' non-standard HTS codes: ',
            paste(head(bad, 5), collapse = ', '))
  }
  invisible(length(bad) == 0)
}


# =============================================================================
# File I/O Helpers
# =============================================================================

#' Get the most recent HTS archive file
#'
#' @param year Year to look for (default: current year)
#' @return Path to most recent JSON file
get_latest_hts_archive <- function(year = format(Sys.Date(), '%Y'),
                                   archive_dir = here('data', 'hts_archives')) {
  files <- list.files(
    archive_dir,
    pattern = paste0('hts_', year, '.*\\.json$'),
    full.names = TRUE
  )

  if (length(files) == 0) {
    stop(paste('No HTS archive found for year', year))
  }

  # Return most recently modified
  file_info <- file.info(files)
  files[which.max(file_info$mtime)]
}

#' Ensure output directory exists
#'
#' @param path Directory path
ensure_dir <- function(path) {
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE)
  }
  return(path)
}


# =============================================================================
# Policy Parameters (YAML)
# =============================================================================

#' Load policy parameters from YAML config
#'
#' Returns a list with convenience fields unpacked for direct use.
#'
#' @param yaml_path Path to policy_params.yaml
#' @param use_policy_dates If TRUE (default), swap date-sensitive config fields
#'   (IEEPA invalidation, S122 effective/expiry) to their policy_effective_date
#'   equivalents. Set FALSE when using --use-hts-dates or for utilities that
#'   need raw HTS timing. See docs/policy_timing.md.
#' @return List with raw params plus convenience fields
load_policy_params <- function(yaml_path = here('config', 'policy_params.yaml'),
                               use_policy_dates = TRUE) {
  if (!file.exists(yaml_path)) {
    stop('Policy params YAML not found: ', yaml_path)
  }

  params <- read_yaml(yaml_path)

  # Unpack convenience fields for country codes
  for (nm in names(params$country_codes)) {
    params[[nm]] <- params$country_codes[[nm]]
  }

  # ISO_TO_CENSUS as named character vector
  params$ISO_TO_CENSUS <- unlist(params$iso_to_census)

  # EU27_CODES as character vector, EU27_NAMES as named vector
  params$EU27_CODES <- names(params$eu27_codes)
  params$EU27_NAMES <- unlist(params$eu27_codes)
  names(params$EU27_NAMES) <- params$EU27_CODES

  # Section 232 chapters as flat vector
  params$SECTION_232_CHAPTERS <- unlist(params$section_232_chapters)

  # Authority columns as named vector
  params$AUTHORITY_COLUMNS <- unlist(params$authority_columns)

  # Section 301 rates as tibble
  if (!is.null(params$section_301_rates)) {
    params$SECTION_301_RATES <- tibble(
      ch99_pattern = map_chr(params$section_301_rates, 'ch99_pattern'),
      s301_rate = map_dbl(params$section_301_rates, 's301_rate')
    )
  }

  # Floor rates
  params$EU_FLOOR_RATE <- params$floor_rates$eu_floor
  params$FLOOR_RATE <- params$floor_rates$floor_rate
  params$FLOOR_COUNTRIES <- unlist(params$floor_rates$floor_countries)

  # Weighted ETR reporting config
  if (!is.null(params$weighted_etr)) {
    if (!is.null(params$weighted_etr$policy_dates)) {
      params$WEIGHTED_ETR_POLICY_DATES <- tibble(
        date = as.Date(map_chr(params$weighted_etr$policy_dates, 'date')),
        label = map_chr(params$weighted_etr$policy_dates, 'label')
      )
    }
    if (!is.null(params$weighted_etr$tpc_name_fixes)) {
      params$TPC_NAME_FIXES <- unlist(params$weighted_etr$tpc_name_fixes)
    }
  }

  # IEEPA invalidation date (SCOTUS ruling)
  if (!is.null(params$ieepa_invalidation_date)) {
    params$IEEPA_INVALIDATION_DATE <- as.Date(params$ieepa_invalidation_date)
  } else {
    params$IEEPA_INVALIDATION_DATE <- NULL
  }

  # Swiss/Liechtenstein framework (EO 14346)
  if (!is.null(params$swiss_framework)) {
    params$SWISS_FRAMEWORK <- list(
      effective_date = as.Date(params$swiss_framework$effective_date),
      expiry_date = as.Date(params$swiss_framework$expiry_date),
      finalized = isTRUE(params$swiss_framework$finalized),
      countries = unlist(params$swiss_framework$countries)
    )
  }

  # USMCA utilization shares (DataWeb SPI S/S+)
  params$USMCA_SHARES <- list(
    mode = params$usmca_shares$mode %||% 'annual',
    year = params$usmca_shares$year %||% NULL,
    month = params$usmca_shares$month %||% NULL
  )

  # MFN exemption shares (FTA/GSP preference utilization)
  if (!is.null(params$mfn_exemption)) {
    params$MFN_EXEMPTION <- list(
      method = params$mfn_exemption$method %||% 'none',
      exclude_usmca_countries = isTRUE(params$mfn_exemption$exclude_usmca_countries)
    )
  } else {
    params$MFN_EXEMPTION <- list(method = 'none', exclude_usmca_countries = TRUE)
  }

  # Section 232 country exemptions (TRQ/quota agreements)
  if (!is.null(params$section_232_country_exemptions)) {
    params$S232_COUNTRY_EXEMPTIONS <- map(params$section_232_country_exemptions, function(entry) {
      # Expand 'eu' mnemonic to EU27 codes
      raw_countries <- unlist(entry$countries)
      expanded <- if ('eu' %in% raw_countries) {
        c(setdiff(raw_countries, 'eu'), params$EU27_CODES)
      } else {
        raw_countries
      }
      list(
        countries = expanded,
        rate = entry$rate,
        applies_to = unlist(entry$applies_to),
        expiry_date = if (!is.null(entry$expiry_date)) as.Date(entry$expiry_date) else NULL
      )
    })
  } else {
    params$S232_COUNTRY_EXEMPTIONS <- list()
  }

  # Series horizon
  if (!is.null(params$series_horizon$end_date)) {
    params$SERIES_HORIZON_END <- as.Date(params$series_horizon$end_date)
  } else {
    params$SERIES_HORIZON_END <- Sys.Date()
  }

  # Section 122 (Trade Act §122, 150-day statutory limit)
  if (!is.null(params$section_122)) {
    params$SECTION_122 <- list(
      effective_date = as.Date(params$section_122$effective_date),
      expiry_date = as.Date(params$section_122$expiry_date),
      finalized = isTRUE(params$section_122$finalized)
    )
  }

  # Swap policy dates if requested (SCOTUS ruling + S122 coordination)
  if (use_policy_dates) {
    if (!is.null(params$ieepa_invalidation_policy_date)) {
      params$IEEPA_INVALIDATION_DATE <- as.Date(params$ieepa_invalidation_policy_date)
      message('  Policy dates: IEEPA invalidation -> ', params$IEEPA_INVALIDATION_DATE)
    }
    if (!is.null(params$section_122$policy_effective_date)) {
      params$SECTION_122$effective_date <- as.Date(params$section_122$policy_effective_date)
      message('  Policy dates: S122 effective -> ', params$SECTION_122$effective_date)
    }
    if (!is.null(params$section_122$policy_expiry_date)) {
      params$SECTION_122$expiry_date <- as.Date(params$section_122$policy_expiry_date)
      message('  Policy dates: S122 expiry -> ', params$SECTION_122$expiry_date)
    }
  }

  # Section 232 annexes (April 2026 proclamation)
  if (!is.null(params$section_232_annexes)) {
    params$S232_ANNEXES <- params$section_232_annexes
    params$S232_ANNEXES$effective_date <- as.Date(params$section_232_annexes$effective_date)
  }

  # Section 201 (Trade Act §201 safeguards). Currently models Solar 201:
  # the HTS lists out-of-quota rates that don't reflect annual step-down,
  # so we override with the published current rate.
  if (!is.null(params$section_201)) {
    params$SECTION_201 <- params$section_201
  }

  # Section 301 forced labor (60 economies; 91 FR 47318 / 91 FR 47717).
  # The UPPER-case key is what collect_activation_adjustments() looks for, so
  # presence of this block is what arms the 2026-07-24 activation gate.
  if (!is.null(params$section_301_forced_labor)) {
    params$SECTION_301_FORCED_LABOR <- params$section_301_forced_labor
    params$SECTION_301_FORCED_LABOR$effective_date <-
      as.Date(params$section_301_forced_labor$effective_date)
    if (!is.null(params$section_301_forced_labor$patented_pharma_exempt_date)) {
      params$SECTION_301_FORCED_LABOR$patented_pharma_exempt_date <-
        as.Date(params$section_301_forced_labor$patented_pharma_exempt_date)
    }
    # Country scope = the union of the four tiers. collect_activation_adjustments()
    # reads `countries` for its gate scope; without it the gate would zero
    # rate_s301fl for every country, including the investigated ones.
    fl <- params$SECTION_301_FORCED_LABOR
    params$SECTION_301_FORCED_LABOR$countries <- unique(c(
      fl$tier_10pct, fl$tier_10pct_net_mfn,
      fl$tier_12_5pct, fl$tier_12_5pct_net_mfn
    ))
  }

  # Section 301 Brazil (91 FR 45516). Same arming semantics as above.
  if (!is.null(params$section_301_brazil)) {
    params$SECTION_301_BRAZIL <- params$section_301_brazil
    params$SECTION_301_BRAZIL$effective_date <-
      as.Date(params$section_301_brazil$effective_date)
  }

  # Local paths (optional user-specific file locations)
  params$LOCAL_PATHS <- load_local_paths()

  return(params)
}


#' Load optional local paths configuration
#'
#' Reads config/local_paths.yaml if present. Returns a named list of paths,
#' with NULL for any unset entries. Never required for core build.
#'
#' @param yaml_path Path to local_paths.yaml
#' @return Named list with import_weights, tpc_benchmark, tariff_etrs_repo
get_country_constants <- function(pp = NULL) {
  if (is.null(pp)) pp <- tryCatch(load_policy_params(), error = function(e) NULL)
  list(
    CTY_CHINA  = if (!is.null(pp)) pp$CTY_CHINA  else '5700',
    CTY_CANADA = if (!is.null(pp)) pp$CTY_CANADA else '1220',
    CTY_MEXICO = if (!is.null(pp)) pp$CTY_MEXICO else '2010',
    CTY_JAPAN  = if (!is.null(pp)) pp$CTY_JAPAN  else '5880',
    CTY_UK     = if (!is.null(pp)) pp$CTY_UK     else '4120',
    CTY_HK     = if (!is.null(pp)) pp$CTY_HK     else '5820',
    EU27_CODES = if (!is.null(pp)) pp$EU27_CODES else c(
      '4330', '4231', '4870', '4791', '4910', '4351', '4099', '4470', '4050',
      '4279', '4280', '4840', '4370', '4190', '4759', '4490', '4510', '4239',
      '4730', '4210', '4550', '4710', '4850', '4359', '4792', '4700', '4010'
    ),
    EU27_NAMES = if (!is.null(pp)) pp$EU27_NAMES else c(
      '4330' = 'Austria', '4231' = 'Belgium', '4870' = 'Bulgaria',
      '4791' = 'Croatia', '4910' = 'Cyprus', '4351' = 'Czech Republic',
      '4099' = 'Denmark', '4470' = 'Estonia', '4050' = 'Finland',
      '4279' = 'France', '4280' = 'Germany', '4840' = 'Greece',
      '4370' = 'Hungary', '4190' = 'Ireland', '4759' = 'Italy',
      '4490' = 'Latvia', '4510' = 'Lithuania', '4239' = 'Luxembourg',
      '4730' = 'Malta', '4210' = 'Netherlands', '4550' = 'Poland',
      '4710' = 'Portugal', '4850' = 'Romania', '4359' = 'Slovakia',
      '4792' = 'Slovenia', '4700' = 'Spain', '4010' = 'Sweden'
    ),
    ISO_TO_CENSUS = if (!is.null(pp)) pp$ISO_TO_CENSUS else tryCatch(
      build_full_iso_census_map(),
      error = function(e) c(
        'CN' = '5700', 'CA' = '1220', 'MX' = '2010',
        'JP' = '5880', 'UK' = '4120', 'GB' = '4120',
        'AU' = '6021', 'KR' = '5800', 'RU' = '4621',
        'AR' = '3570', 'BR' = '3510', 'UA' = '4623'
      )
    ),
    STEEL_CHAPTERS = if (!is.null(pp)) pp$section_232_chapters$steel else c('72', '73'),
    ALUM_CHAPTERS  = if (!is.null(pp)) pp$section_232_chapters$aluminum else c('76')
  )
}


load_local_paths <- function(yaml_path = here('config', 'local_paths.yaml')) {
  defaults <- list(
    import_weights = NULL,
    tpc_benchmark = 'data/tpc/tariff_by_flow_day.csv',
    tariff_etrs_repo = NULL
  )

  if (!file.exists(yaml_path)) return(defaults)

  raw <- tryCatch(read_yaml(yaml_path), error = function(e) {
    warning('Failed to parse local_paths.yaml: ', conditionMessage(e))
    return(list())
  })

  # Merge with defaults (YAML nulls become R NULLs)
  for (nm in names(defaults)) {
    if (!is.null(raw[[nm]])) defaults[[nm]] <- raw[[nm]]
  }
  return(defaults)
}


# =============================================================================
# Revision / Archive Helpers
# =============================================================================

#' Parse a revision identifier into year and revision type
#'
#' Handles both year-prefixed and plain formats:
#'   '2026_rev_3'  -> list(year=2026, rev='rev_3')
#'   '2026_basic'  -> list(year=2026, rev='basic')
#'   'rev_32'      -> list(year=2025, rev='rev_32')
#'   'basic'       -> list(year=2025, rev='basic')
#'
#' @param revision Character revision identifier
#' @return List with year (integer) and rev (character) components
parse_revision_id <- function(revision) {
  if (grepl('^[0-9]{4}_', revision)) {
    year <- as.integer(substr(revision, 1, 4))
    rev <- sub('^[0-9]{4}_', '', revision)
    return(list(year = year, rev = rev))
  }
  return(list(year = 2025L, rev = revision))
}


#' Build USITC release name from revision identifier
#'
#' Maps a revision ID to the USITC release name used in API URLs.
#' Returns NA for pre-2025 revisions (no API access).
#'
#' @param revision Character revision identifier (e.g., 'rev_18', '2026_basic')
#' @return Character release name (e.g., '2025HTSRev18') or NA
build_release_name <- function(revision) {
  parsed <- parse_revision_id(revision)
  year <- parsed$year
  rev <- parsed$rev

  if (year < 2025) return(NA_character_)

  if (rev == 'basic') {
    return(paste0(year, 'HTSBasic'))
  }

  # Extract numeric part from rev_N
  rev_num <- as.integer(sub('^rev_', '', rev))
  if (is.na(rev_num)) return(NA_character_)

  return(paste0(year, 'HTSRev', rev_num))
}


#' Build USITC Chapter 99 PDF download URL
#'
#' Uses the USITC reststop file endpoint to construct a URL for downloading
#' the Chapter 99 PDF for a specific HTS release.
#'
#' @param release_name Character release name from build_release_name()
#' @return Character URL string
build_chapter99_url <- function(release_name) {
  paste0('https://hts.usitc.gov/reststop/file?release=',
         URLencode(release_name, reserved = TRUE),
         '&filename=Chapter+99')
}


#' Load revision dates from config CSV
#'
#' @param csv_path Path to revision_dates.csv
#' @param use_policy_dates If TRUE (default), swap policy_effective_date into
#'   effective_date where populated. This uses legal policy dates instead of
#'   HTS revision dates. Set FALSE or pass --use-hts-dates to use raw HTS dates.
#'   See docs/policy_timing.md for details on which revisions are affected.
#' @return Tibble with revision, effective_date, tpc_date
load_revision_dates <- function(csv_path = here('config', 'revision_dates.csv'),
                                use_policy_dates = TRUE) {
  if (!file.exists(csv_path)) {
    stop('Revision dates CSV not found: ', csv_path,
         '\nRun scraper or create manually.')
  }

  # Read with known columns; any extra columns (e.g., needs_review) are
  # auto-typed so the spec doesn't warn when they're absent from the CSV.
  dates <- read_csv(csv_path, col_types = cols(
    revision = col_character(),
    effective_date = col_date(),
    policy_effective_date = col_date(),
    tpc_date = col_date(),
    policy_event = col_character(),
    tpc_policy_revision = col_character()
  ))

  # Validate
  stopifnot(all(!is.na(dates$revision)))
  stopifnot(all(!is.na(dates$effective_date)))
  stopifnot(!any(duplicated(dates$revision)))

  # Check for unresolved placeholder dates
  if ('needs_review' %in% names(dates)) {
    unreviewed <- dates %>% filter(!is.na(needs_review) & needs_review == 'TRUE')
    if (nrow(unreviewed) > 0) {
      stop(
        nrow(unreviewed), ' revision(s) have unreviewed placeholder dates:\n',
        paste0('  ', unreviewed$revision, '  effective_date=', unreviewed$effective_date,
               collapse = '\n'),
        '\n\nThe API publication date is NOT the policy effective date.',
        '\nOpen config/revision_dates.csv, set the correct effective_date,',
        '\nand remove or clear the needs_review column for these rows.'
      )
    }
    # Drop the column after validation — downstream code doesn't need it
    dates <- dates %>% select(-needs_review)
  }

  # Optionally swap policy_effective_date into effective_date
  if (use_policy_dates && 'policy_effective_date' %in% names(dates)) {
    n_swapped <- sum(!is.na(dates$policy_effective_date))
    if (n_swapped > 0) {
      dates <- dates %>%
        mutate(effective_date = if_else(!is.na(policy_effective_date),
                                        policy_effective_date,
                                        effective_date))
      message('  Policy dates: swapped ', n_swapped, ' revision effective dates')
    }
  }

  # Sort by effective_date
  dates <- dates %>% arrange(effective_date)

  message('Loaded ', nrow(dates), ' revision dates from ', csv_path)
  message('  Date range: ', min(dates$effective_date), ' to ', max(dates$effective_date))
  message('  TPC validation dates: ', sum(!is.na(dates$tpc_date)))

  return(dates)
}


#' List available HTS JSON archives
#'
#' Scans the archive directory and returns revision identifiers.
#'
#' @param archive_dir Path to HTS JSON archive directory
#' @param year Year prefix (default: 2025)
#' @return Character vector of revision identifiers
list_available_revisions <- function(archive_dir = here('data', 'hts_archives'), year = 2025) {
  files <- list.files(archive_dir, pattern = paste0('hts_', year, '.*\\.json$'))

  # Extract revision from filename: hts_2025_rev_32.json -> rev_32, hts_2025_basic.json -> basic
  revisions <- str_match(files, paste0('hts_', year, '_(.+)\\.json'))[, 2]
  revisions <- revisions[!is.na(revisions)]

  return(revisions)
}


#' Resolve JSON path for a revision
#'
#' @param revision Revision identifier (e.g., 'basic', 'rev_1')
#' @param archive_dir HTS archive directory
#' @param year HTS year (default: 2025)
#' @return Full file path to JSON
resolve_json_path <- function(revision, archive_dir = here('data', 'hts_archives'), year = 2025) {
  parsed <- parse_revision_id(revision)
  path <- file.path(archive_dir, paste0('hts_', parsed$year, '_', parsed$rev, '.json'))

  if (!file.exists(path)) {
    stop('HTS JSON not found: ', path)
  }

  return(path)
}


#' Get available revisions across all years
#'
#' Scans the archive directory for all years present in a revision list
#' and returns full revision identifiers (with year prefix for non-2025).
#'
#' @param all_revisions Character vector of revision IDs from revision_dates.csv
#' @param archive_dir Path to HTS archive directory
#' @return Character vector of available revision identifiers
get_available_revisions_all_years <- function(all_revisions, archive_dir = here('data', 'hts_archives')) {
  years_needed <- unique(map_int(all_revisions, ~ parse_revision_id(.)$year))
  available <- character()
  for (yr in years_needed) {
    yr_revisions <- list_available_revisions(archive_dir, year = yr)
    # Always prefix with year for consistency (2025_basic, 2025_rev_1, etc.)
    yr_revisions <- paste0(yr, '_', yr_revisions)
    available <- c(available, yr_revisions)
  }
  return(available)
}


# =============================================================================
# HTS Concordance
# =============================================================================

#' Load and chain HTS product concordance for import remapping
#'
#' Reads the concordance CSV and builds a cumulative old->new mapping between
#' two revisions. Used to remap import product codes (which may reflect an
#' older HTS edition) to match snapshot product codes.
#'
#' @param concordance_path Path to hts_concordance.csv
#' @return Tibble with old_hts10, new_hts10, change_type columns
load_hts_concordance <- function(concordance_path = here('resources', 'hts_concordance.csv')) {
  if (!file.exists(concordance_path)) {
    warning('Concordance file not found: ', concordance_path)
    return(tibble(old_hts10 = character(), new_hts10 = character(), change_type = character()))
  }
  read_csv(concordance_path, col_types = cols(.default = col_character(),
                                               similarity = col_double()))
}


#' Remap import product codes using HTS concordance
#'
#' For imports whose hts10 does not appear in the snapshot, looks up the
#' concordance chain to find the successor code. Handles renames, splits,
#' and many-to-many mappings. When a code splits into multiple successors,
#' import value is divided equally among successors.
#'
#' @param imports Tibble with hts10, country (country_code), value columns
#' @param snapshot_codes Character vector of hts10 codes in the active snapshot
#' @param concordance Tibble from load_hts_concordance()
#' @return imports tibble with remapped hts10 codes and a `remapped` flag
remap_imports_via_concordance <- function(imports, snapshot_codes, concordance) {
  if (nrow(concordance) == 0) return(imports %>% mutate(remapped = FALSE))

  # Build old->new mapping (renames, splits, many_to_many — not 'added'/'dropped')
  mapping <- concordance %>%
    filter(!is.na(old_hts10), !is.na(new_hts10)) %>%
    select(old_hts10, new_hts10) %>%
    distinct()

  # Chain through transitive mappings (old->intermediate->new)
  # Iterate until stable — handles multi-step renames across revisions
  for (iter in 1:10) {
    chained <- mapping %>%
      inner_join(mapping, by = c('new_hts10' = 'old_hts10'), suffix = c('', '.next')) %>%
      filter(new_hts10.next != old_hts10)  # avoid cycles

    if (nrow(chained) == 0) break

    extended <- chained %>%
      select(old_hts10, new_hts10 = new_hts10.next) %>%
      distinct()

    # Replace intermediate mappings with chained ones
    mapping <- mapping %>%
      anti_join(chained %>% select(old_hts10, new_hts10), by = c('old_hts10', 'new_hts10')) %>%
      bind_rows(extended) %>%
      distinct()
  }

  # Only remap codes that are (a) missing from snapshot and (b) have a successor in snapshot
  missing_codes <- setdiff(unique(imports$hts10), snapshot_codes)
  useful_mapping <- mapping %>%
    filter(old_hts10 %in% missing_codes, new_hts10 %in% snapshot_codes)

  if (nrow(useful_mapping) == 0) return(imports %>% mutate(remapped = FALSE))

  # Count successors per old code (for splits, divide value equally)
  successor_counts <- useful_mapping %>% count(old_hts10, name = 'n_successors')
  useful_mapping <- useful_mapping %>% left_join(successor_counts, by = 'old_hts10')

  # Split imports into remappable and not
  imports_remap <- imports %>%
    filter(hts10 %in% useful_mapping$old_hts10) %>%
    inner_join(useful_mapping, by = c('hts10' = 'old_hts10'), relationship = 'many-to-many') %>%
    mutate(
      hts10 = new_hts10,
      value = value / n_successors,
      remapped = TRUE
    ) %>%
    select(-new_hts10, -n_successors)

  imports_keep <- imports %>%
    filter(!hts10 %in% useful_mapping$old_hts10) %>%
    mutate(remapped = FALSE)

  result <- bind_rows(imports_keep, imports_remap)

  n_remapped <- sum(result$remapped)
  if (n_remapped > 0) {
    cat('  Concordance: remapped', n_remapped, 'import rows (',
        length(unique(useful_mapping$old_hts10)), 'codes)\n')
  }

  return(result)
}


# =============================================================================
# Rate Schema
# =============================================================================

#' Canonical column vector for rate output
#'
#' Design notes on quantity/unit fields (per U.S. HTSUS methodology):
#'   - reported_unit_1/2: Statistical reporting units from the HTS 10-digit line.
#'     These are nonlegal statistical elements required on customs entry documents.
#'     They do NOT by themselves drive duty calculation.
#'   - duty_basis_unit: The unit extracted from the legal rate expression (e.g., "kg"
#'     from "30.5¢/kg + 8.5%", "pf.liter" from "2.1¢/pf.liter"). This is the unit
#'     that enters the duty math for specific/compound rates.
#'   - is_qty_duty_relevant: TRUE only when rate_basis is 'specific' or 'compound'.
#'     For ad valorem rates, duty is on customs value, not quantity.
#'   - quantity_source: Where the duty_basis_unit was derived from (rate_text,
#'     chapter_note, override, or NA if not quantity-relevant).
#'   - rounding_rule: Which 19 CFR 159.3 rounding applies:
#'     "19cfr159.3_value" for ad valorem (value in even dollars),
#'     "19cfr159.3_specific_lte1" for specific rates <= $1/unit,
#'     "19cfr159.3_specific_gt1" for specific rates > $1/unit.
#' Per-authority additional-duty rate columns — SINGLE SOURCE OF TRUTH
#'
#' Every column here is an additional ad valorem duty that stacks onto base_rate.
#' This list previously existed as ~14 hardcoded copies across src/ (zero-fill
#' initializers, select() lists, NA-fill lists, export column sets). Adding an
#' authority therefore meant editing all of them, and missing one produced silent
#' NAs that got coalesced to 0 — i.e. a duty quietly dropped. Use this constant
#' (or zero_fill_authority_rates()) instead of writing the list out again.
#'
#' NB: 'rate_other' stays LAST so downstream code that treats it as the residual
#' bucket keeps working.
AUTHORITY_RATE_COLS <- c(
  'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent',
  'rate_s122', 'rate_section_201', 'rate_s301fl', 'rate_s301br', 'rate_other'
)


#' Add any missing per-authority rate column as 0
#'
#' Use in place of hand-written `rate_x = 0, rate_y = 0, ...` initializers so a
#' new authority is picked up automatically.
#'
#' @param df Data frame
#' @param cols Columns to ensure (default: all authority rate columns)
#' @return df with every requested column present and NA-free
zero_fill_authority_rates <- function(df, cols = AUTHORITY_RATE_COLS) {
  for (col in cols) {
    if (!col %in% names(df)) {
      df[[col]] <- 0
    } else {
      df[[col]][is.na(df[[col]])] <- 0
    }
  }
  df
}


RATE_SCHEMA <- c(
  'hts10', 'country', 'base_rate', 'statutory_base_rate',
  'rate_232', 'rate_301', 'rate_ieepa_recip', 'rate_ieepa_fent',
  'rate_s122', 'rate_section_201', 'rate_s301fl', 'rate_s301br', 'rate_other',
  'ch99_code_232', 'ch99_code_301', 'ch99_code_ieepa_recip',
  'ch99_code_ieepa_fent', 'ch99_code_s122', 'ch99_code_s201',
  'metal_share', 's232_annex', 's232_metal', 'duty_basis_232',
  'total_additional', 'total_rate',
  'usmca_eligible',
  'rate_special', 'rate_special_raw', 'special_programs_json',
  'rate_column2', 'rate_column2_raw',
  'rate_basis', 'specific_amount', 'specific_rate_unit',
  'reported_unit_1', 'reported_unit_2',
  'duty_basis_unit', 'is_qty_duty_relevant', 'quantity_source',
  'rounding_rule', 'calc_status', 'base_rate_source',
  'duty_provenance_json', 'ch99_rules_json',
  'revision', 'effective_date',
  'valid_from', 'valid_until'
)

#' Ensure a rates data frame conforms to the canonical schema
#'
#' Adds missing columns with sensible defaults, reorders to canonical order.
#' Extra columns are preserved at the end.
#'
#' @param df Data frame with rate data
#' @return Data frame with all RATE_SCHEMA columns present and ordered first
enforce_rate_schema <- function(df) {
  # Defaults by column
  defaults <- list(
    hts10 = NA_character_, country = NA_character_,
    base_rate = 0, statutory_base_rate = 0, rate_232 = 0, rate_301 = 0,
    rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0,
    rate_s301fl = 0, rate_s301br = 0, rate_other = 0,
    ch99_code_232 = NA_character_, ch99_code_301 = NA_character_,
    ch99_code_ieepa_recip = NA_character_, ch99_code_ieepa_fent = NA_character_,
    ch99_code_s122 = NA_character_, ch99_code_s201 = NA_character_,
    metal_share = 1.0, s232_annex = NA_character_, s232_metal = NA_character_,
    duty_basis_232 = NA_character_,
    total_additional = 0, total_rate = 0,
    usmca_eligible = FALSE,
    rate_special = NA_real_, rate_special_raw = NA_character_,
    special_programs_json = NA_character_,
    rate_column2 = NA_real_, rate_column2_raw = NA_character_,
    rate_basis = 'ad_valorem',
    specific_amount = NA_real_, specific_rate_unit = NA_character_,
    reported_unit_1 = NA_character_, reported_unit_2 = NA_character_,
    duty_basis_unit = NA_character_,
    is_qty_duty_relevant = FALSE, quantity_source = NA_character_,
    rounding_rule = '19cfr159.3_value', calc_status = 'ok', base_rate_source = NA_character_,
    duty_provenance_json = NA_character_,
    ch99_rules_json = NA_character_,
    revision = NA_character_,
    effective_date = as.Date(NA),
    valid_from = as.Date(NA), valid_until = as.Date(NA)
  )

  for (col in RATE_SCHEMA) {
    if (!col %in% names(df)) {
      df[[col]] <- defaults[[col]]
    }
  }

  # Fail loud on a NA effective total (port of upstream c0ff82a8).
  # total_additional/total_rate are computed by apply_stacking_rules() FROM the
  # (already-filled) per-authority rate columns, so a NA here means a rate column
  # was NA when it ENTERED stacking — and NA then poisons the arithmetic
  # (`NA > 0` is NA, `x * NA` is NA). Silently coalescing it to 0, as this
  # function did until this port, masks a real upstream bug: that is exactly how
  # a bare `s232_annex == '<annex>'` if_else condition wipes rate_232 (and with
  # it §122/base) for every non-annex product. Surface it here instead of hiding
  # it. Fix the source; never coalesce.
  for (col in c('total_additional', 'total_rate')) {
    if (!col %in% names(df)) next
    na_idx <- which(is.na(df[[col]]))
    if (length(na_idx) > 0) {
      id_cols <- intersect(c('hts10', 'country'), names(df))
      sample_txt <- if (length(id_cols) > 0) {
        ex <- utils::head(df[na_idx, id_cols, drop = FALSE], 5)
        paste0(' Sample (', paste(id_cols, collapse = '/'), '): ',
               paste(do.call(paste, c(unname(as.list(ex)), sep = '/')),
                     collapse = ', '))
      } else ''
      stop('enforce_rate_schema: ', length(na_idx), ' row(s) have NA ', col,
           ' after stacking — an upstream rate column was NA entering ',
           'apply_stacking_rules() (NA poisons the total). Fix the source; do ',
           'NOT coalesce to 0.', sample_txt)
    }
  }

  # Fill NAs in the per-authority rate columns + base. bind_rows for MFN-only
  # grid pairs legitimately leaves an absent authority column NA — that IS a 0
  # rate. NB: total_additional/total_rate are deliberately NOT in this list —
  # they are guarded above (a NA total is a bug, not a fill-to-0 case).
  rate_cols <- c('base_rate', 'statutory_base_rate', AUTHORITY_RATE_COLS)
  for (col in rate_cols) {
    if (col %in% names(df)) {
      df[[col]][is.na(df[[col]])] <- 0
    }
  }

  # Reorder: schema columns first, then any extras
  extra_cols <- setdiff(names(df), RATE_SCHEMA)
  df <- df[, c(RATE_SCHEMA, extra_cols)]

  return(df)
}

#' ITA-enumerated semiconductor/electronics prefixes on IEEPA Annex II.
#'
#' A named subset of Annex II (U.S. Note 2(v)(iii)). Kept in sync with the
#' literal subheading enumeration in src/expand_ieepa_exempt.R Fix 3.
IEEPA_EXEMPT_ITA_PREFIXES <- c(
  '8471', '847330', '8486', '852351', '8524',
  '85411000', '85412100', '85412900', '85413000', '85414100',
  '85414910', '85414970', '85414980', '85414995', '85415100',
  '85415900', '85419000', '8542'
)

#' Classify the legal provenance of an IEEPA-reciprocal-exempt HTS10
#'
#' Maps an exempt product to the exemption LAYER that covers it, so the
#' frontend can cite the controlling legal authority rather than guess
#' "coverage gap". Mirrors the layering built by src/expand_ieepa_exempt.R:
#'   - 'ch98'     Chapter 98 statutory exemption (U.S. Note 2(v)(i))
#'   - 'berman'   Ch.49 printed matter / Ch.97 art (Berman Amendment, 19 USC 2505)
#'   - 'ita'      ITA-enumerated semiconductor/electronics subheadings (Annex II)
#'   - 'annex_ii' the base Annex II enumeration (U.S. Note 2(v)(iii)) — default
#'
#' These map 1:1 to reason_codes in config/duty_citations.yaml
#' (ieepa_exempt_ch98 / ieepa_exempt_berman / ieepa_exempt_ita / ieepa_exempt_annex_ii).
#'
#' @param hts10 Character vector of 10-digit HTS codes.
#' @return Character vector of sources (same length as input).
classify_exempt_source <- function(hts10) {
  vapply(hts10, function(h) {
    if (is.na(h)) return(NA_character_)
    ch2  <- substr(h, 1, 2)
    hts8 <- substr(h, 1, 8)
    # Chapter 98 statutory exemption — except the 9802 re-import provisions
    # that remain IEEPA-dutiable.
    if (ch2 == '98' && !(hts8 %in% c('98020040', '98020050', '98020060', '98020080'))) {
      return('ch98')
    }
    # Berman Amendment (19 U.S.C. 2505): informational materials.
    if (ch2 %in% c('97', '49')) return('berman')
    # ITA-enumerated semiconductor/electronics subheadings (subset of Annex II).
    for (p in IEEPA_EXEMPT_ITA_PREFIXES) {
      if (substr(h, 1, nchar(p)) == p) return('ita')
    }
    # Default: base Annex II enumeration (U.S. Note 2(v)(iii)).
    'annex_ii'
  }, character(1), USE.NAMES = FALSE)
}

#' Date-window the IEEPA exempt list for one revision
#'
#' The Annex II exempt list (resources/ieepa_exempt_products.csv) is
#' date-windowed: amendments added electronics (Apr 5 2025, retroactive per
#' the Apr 11 memo), EO 14346 metals/gold (Sept 8 2025) and the agricultural
#' expansion (Nov 13 2025); copper and wood were REMOVED when their Section
#' 232 programs began (Aug 1 / Oct 14 2025). effective_date_start/_end are
#' stamped by scripts/build_annex_ii_dates.R; blank = always active. An entry
#' exempts a revision only within [start, end] (end = last day exempt).
#'
#' @param exempt_tbl Tibble with hts10 and optional effective_date_start/_end
#'   character columns.
#' @param effective_date The revision's effective date (Date or string).
#' @return exempt_tbl filtered to entries active at effective_date.
filter_ieepa_exempt_window <- function(exempt_tbl, effective_date) {
  rd <- as.Date(effective_date)
  if ('effective_date_start' %in% names(exempt_tbl)) {
    exempt_tbl <- exempt_tbl %>%
      filter(is.na(effective_date_start) |
               as.Date(effective_date_start) <= rd)
  }
  if ('effective_date_end' %in% names(exempt_tbl)) {
    exempt_tbl <- exempt_tbl %>%
      filter(is.na(effective_date_end) |
               as.Date(effective_date_end) >= rd)
  }
  exempt_tbl
}

#' Attach per-authority duty provenance as a compact JSON column
#'
#' Stamps each row with `duty_provenance_json` — a structured explanation of
#' WHY each authority's rate is what it is, so the frontend can cite the legal
#' basis and tell an INTENTIONAL EXEMPTION apart from a COVERAGE GAP instead of
#' guessing from `rate == 0`.
#'
#' Per non-trivial authority slot the JSON carries:
#'   status   active | exempt | not_applicable
#'   reason   a code resolved against config/duty_citations.yaml (legal text)
#'   applied  the rate SAIL applied (omitted when 0)
#'   counterfactual  the rate a broker WOULD bill absent the exemption (exempt only)
#'   program_ch99    the would-apply Chapter 99 heading (e.g. 9903.02.20)
#' not_applicable slots are omitted; parquet dictionary-compresses the repeated
#' base-only rows to near nothing.
#'
#' This is PURE post-processing of the final rate columns plus the IEEPA country
#' frame — it never changes a computed rate, so it cannot perturb the duty math.
#'
#' @param rates Final rates tibble (post enforce_rate_schema).
#' @param country_ieepa Per-census_code IEEPA frame (ieepa_country_rate, ieepa_type,
#'   ieepa_recip_ch99, is_universal_baseline_country), or NULL when no IEEPA.
#' @param ieepa_exempt_source_map Named vector hts10 -> source (annex_ii/ita/ch98/berman).
#' @param ieepa_exempt_scope 'all' | 'baseline_only'.
#' @param duty_free_treatment 'all_products' | 'nonzero_base_only'.
#' @param cc Country-code list (CTY_CHINA / CTY_CANADA / CTY_MEXICO).
#' @param ch99_other 9902 MTB / 9904 ag-safeguard candidates from
#'   parse_chapter99_other() (trigger-matched requires-more-facts rules).
#' @param s301_exclusions Tibble (hts10, ch99_code) of in-window §301
#'   exclusion-heading candidates from build_s301_exclusion_candidates().
#'   Exclusions are description-scoped slices of a line, so they emit as
#'   'potentially_applicable_requires_more_facts' rules on rows where §301
#'   is applied — never as rate changes.
#' @return rates with `duty_provenance_json` populated.
attach_duty_provenance <- function(rates, country_ieepa = NULL,
                                   ieepa_exempt_source_map = NULL,
                                   ieepa_exempt_scope = 'all',
                                   duty_free_treatment = 'all_products',
                                   cc = NULL,
                                   ch99_other = NULL,
                                   s301_exclusions = NULL) {
  n <- nrow(rates)
  if (n == 0) {
    rates$duty_provenance_json <- character(0)
    rates$ch99_rules_json <- character(0)
    return(rates)
  }
  EPS <- 1e-9

  gv  <- function(nm, default = NA) if (nm %in% names(rates)) rates[[nm]] else rep(default, n)
  num <- function(nm) { v <- as.numeric(gv(nm, 0)); v[is.na(v)] <- 0; v }
  chr <- function(nm) as.character(gv(nm, NA_character_))

  hts10 <- chr('hts10'); country <- chr('country'); base_rate <- num('base_rate')
  statutory_base <- num('statutory_base_rate')
  r232 <- num('rate_232'); r301 <- num('rate_301'); rrec <- num('rate_ieepa_recip')
  rfent <- num('rate_ieepa_fent'); rs122 <- num('rate_s122'); r201 <- num('rate_section_201')
  c232 <- chr('ch99_code_232'); c301 <- chr('ch99_code_301'); crec <- chr('ch99_code_ieepa_recip')
  cfent <- chr('ch99_code_ieepa_fent'); cs122 <- chr('ch99_code_s122'); cs201 <- chr('ch99_code_s201')
  deriv <- chr('deriv_type'); usmca <- as.logical(gv('usmca_eligible', FALSE)); usmca[is.na(usmca)] <- FALSE
  # §232 coverage source: the annex tier (bucket) + the covered metal, both set
  # in 06 from the annex product list (NOT the 9903.82 reporting code, which is
  # ambiguous in the annex era). NA for pre-annex rows → ch99-code fallback below.
  s232_annex <- chr('s232_annex'); s232_metal <- chr('s232_metal')

  CTY_CHINA  <- if (!is.null(cc) && !is.null(cc$CTY_CHINA))  cc$CTY_CHINA  else '5700'
  CTY_CANADA <- if (!is.null(cc) && !is.null(cc$CTY_CANADA)) cc$CTY_CANADA else '1220'
  CTY_MEXICO <- if (!is.null(cc) && !is.null(cc$CTY_MEXICO)) cc$CTY_MEXICO else '2010'

  # ---- IEEPA reciprocal: re-join the per-country would-apply rate/type/code ----
  ci_rate <- rep(NA_real_, n); ci_type <- rep(NA_character_, n)
  ci_ch99 <- rep(NA_character_, n); ci_base <- rep(FALSE, n)
  if (!is.null(country_ieepa) && nrow(country_ieepa) > 0) {
    idx <- match(country, country_ieepa$census_code)
    ci_rate <- country_ieepa$ieepa_country_rate[idx]
    ci_type <- country_ieepa$ieepa_type[idx]
    if ('ieepa_recip_ch99' %in% names(country_ieepa)) ci_ch99 <- country_ieepa$ieepa_recip_ch99[idx]
    if ('is_universal_baseline_country' %in% names(country_ieepa)) {
      ci_base <- dplyr::coalesce(country_ieepa$is_universal_baseline_country[idx], FALSE)
    }
  }
  ie_src <- if (!is.null(ieepa_exempt_source_map)) unname(ieepa_exempt_source_map[hts10]) else rep(NA_character_, n)
  is_exempt <- !is.na(ie_src)
  exempt_active <- is_exempt & (ieepa_exempt_scope == 'all' |
                                  (ieepa_exempt_scope == 'baseline_only' & ci_base))
  # Counterfactual = reciprocal that WOULD apply absent the exemption (pre-stacking).
  ie_cf <- dplyr::case_when(
    is.na(ci_rate) ~ 0,
    ci_type == 'surcharge' ~ ci_rate,
    ci_type == 'floor' ~ pmax(0, ci_rate - base_rate),
    TRUE ~ 0
  )
  ie_status <- dplyr::case_when(
    rrec > EPS ~ 'active',
    exempt_active ~ 'exempt',
    !is.na(ci_rate) & ie_cf > EPS ~ 'exempt',   # program would bill but SAIL zeroed it
    TRUE ~ 'not_applicable'
  )
  ie_reason <- dplyr::case_when(
    rrec > EPS & ci_type == 'floor' ~ 'ieepa_recip_floor',
    rrec > EPS ~ 'ieepa_recip_active',
    exempt_active & ie_src == 'ita' ~ 'ieepa_exempt_ita',
    exempt_active & ie_src == 'ch98' ~ 'ieepa_exempt_ch98',
    exempt_active & ie_src == 'berman' ~ 'ieepa_exempt_berman',
    exempt_active ~ 'ieepa_exempt_annex_ii',
    duty_free_treatment == 'nonzero_base_only' & base_rate < 0.001 ~ 'ieepa_duty_free_exempt',
    !is.na(ci_rate) & ie_cf > EPS ~ 'ieepa_floor_exempt',
    TRUE ~ NA_character_
  )
  ie_prog <- dplyr::coalesce(crec, ci_ch99)

  # ---- Section 232 ----
  # COVERAGE SOURCE = the annex tier (s232_annex: 1a primary metal, 1b/3
  # downstream derivative) + the covered metal (s232_metal), both derived in 06
  # from the annex product list. This is authoritative in the annex era, where
  # the 9903.82.xx reporting code does NOT distinguish metal or primary-vs-
  # derivative. Pre-annex rows have NA annex/metal and fall through to the
  # metal-specific ch99 headings (9903.80/81 steel, .85 aluminum, .78 copper).
  # Country overrides (Russia 200%, Turkey surtax) are checked first.
  s232_is_annex <- !is.na(s232_annex) & s232_annex %in% c('annex_1a', 'annex_1b', 'annex_3')
  s232_is_deriv <- !is.na(s232_annex) & s232_annex %in% c('annex_1b', 'annex_3')
  s232_status <- ifelse(r232 > EPS, 'active', 'not_applicable')
  s232_reason <- dplyr::case_when(
    r232 <= EPS ~ NA_character_,
    r232 >= 1.99 ~ 's232_russia_proc10522',
    !is.na(c232) & startsWith(c232, '9903.80.02') ~ 's232_turkey_surtax',
    # --- Annex era: (tier + metal) is the coverage source ---
    s232_is_annex & s232_metal == 'copper'   &  s232_is_deriv ~ 's232_copper_derivative',
    s232_is_annex & s232_metal == 'copper'   & !s232_is_deriv ~ 's232_copper',
    s232_is_annex & s232_metal == 'steel'    &  s232_is_deriv ~ 's232_steel_derivative',
    s232_is_annex & s232_metal == 'steel'    & !s232_is_deriv ~ 's232_steel',
    s232_is_annex & s232_metal == 'aluminum' &  s232_is_deriv ~ 's232_aluminum_derivative',
    s232_is_annex & s232_metal == 'aluminum' & !s232_is_deriv ~ 's232_aluminum',
    # annex-classified but metal not named (downstream derivative absent from the
    # CSV metal_type): still a derivative — keep the generic derivative reason.
    s232_is_annex & s232_is_deriv ~ 's232_steel_derivative',
    # --- Pre-annex / non-metal sectors: the ch99 heading is the coverage source ---
    !is.na(c232) & grepl('^9903\\.8[01]', c232) & deriv == 'steel' ~ 's232_steel_derivative',
    !is.na(c232) & grepl('^9903\\.8[01]', c232) ~ 's232_steel',
    !is.na(c232) & grepl('^9903\\.85', c232) & deriv == 'aluminum' ~ 's232_aluminum_derivative',
    !is.na(c232) & grepl('^9903\\.85', c232) ~ 's232_aluminum',
    !is.na(c232) & grepl('^9903\\.78', c232) ~ 's232_copper',
    !is.na(c232) & grepl('^9903\\.94', c232) ~ 's232_auto',
    !is.na(c232) & grepl('^9903\\.79', c232) ~ 's232_semiconductor',
    !is.na(c232) & grepl('^9903\\.74', c232) ~ 's232_mhd',
    !is.na(c232) & grepl('^9903\\.76', c232) ~ 's232_wood',
    deriv == 'steel' ~ 's232_steel_derivative',
    deriv == 'aluminum' ~ 's232_aluminum_derivative',
    TRUE ~ 'other_ch99'
  )

  s301_status <- ifelse(r301 > EPS, 'active', 'not_applicable')
  s301_reason <- ifelse(r301 > EPS, 's301_active', NA_character_)

  fent_status <- ifelse(rfent > EPS, 'active', 'not_applicable')
  fent_reason <- dplyr::case_when(
    rfent <= EPS ~ NA_character_,
    country == CTY_CANADA ~ 'ieepa_fent_canada',
    country == CTY_MEXICO ~ 'ieepa_fent_mexico',
    TRUE ~ 'ieepa_fent_china'
  )

  s122_status <- ifelse(rs122 > EPS, 'active', 'not_applicable')
  s122_reason <- ifelse(rs122 > EPS, 's122_active', NA_character_)

  s201_status <- ifelse(r201 > EPS, 'active', 'not_applicable')
  s201_reason <- dplyr::case_when(
    r201 <= EPS ~ NA_character_,
    !is.na(cs201) & grepl('^9903\\.45', cs201) ~ 's201_solar',
    TRUE ~ 's201_active'
  )

  # ---- Base / MFN tier reasoning ----
  # statutory_base_rate = Column 1 General (MFN). base_rate = the EFFECTIVE base
  # after the FTA/GSP preference-utilization blend (06 step 6c) or the USMCA
  # HTS10 shares (step 7). base_pref_share = how far the effective rate sits
  # below statutory MFN — i.e. the share of this origin's trade entering under a
  # preference. This is why a specific country's effective base can be far below
  # the headline MFN rate.
  is_camx <- country %in% c(CTY_CANADA, CTY_MEXICO)
  base_pref_share <- ifelse(statutory_base > EPS,
                            pmax(0, pmin(1, 1 - base_rate / statutory_base)), 0)
  base_reason <- dplyr::case_when(
    statutory_base < EPS ~ 'base_free',                       # Column 1 General is Free
    base_pref_share > 0.005 & is_camx ~ 'base_usmca_blended', # CA/MX, HTS10 USMCA shares
    base_pref_share > 0.005 ~ 'base_mfn_blended',             # FTA/GSP HS2 utilization blend
    TRUE ~ 'base_mfn_col1'                                    # full statutory MFN, no preference
  )
  base_source <- dplyr::case_when(
    base_reason == 'base_usmca_blended' ~ 'usmca_hts10',
    base_reason == 'base_mfn_blended' ~ 'census_mfn_hs2',
    TRUE ~ NA_character_
  )

  # ---- Vectorized JSON assembly (no per-row toJSON; parquet-friendly) ----
  fmt <- function(x) {
    s <- sprintf('%.5f', round(as.numeric(x), 5))
    s <- sub('0+$', '', s); sub('\\.$', '', s)
  }
  frag <- function(key, status, reason, applied = NULL, counterfactual = NULL,
                   prog = NULL, extra = NULL, first = FALSE) {
    keep <- !is.na(status) & status %in% c('active', 'exempt') & !is.na(reason)
    s <- paste0('"', key, '":{"status":"', status, '","reason":"', reason, '"')
    if (!is.null(applied)) s <- ifelse(applied > EPS, paste0(s, ',"applied":', fmt(applied)), s)
    if (!is.null(counterfactual)) {
      s <- ifelse(status == 'exempt' & !is.na(counterfactual) & counterfactual > EPS,
                  paste0(s, ',"counterfactual":', fmt(counterfactual)), s)
    }
    if (!is.null(prog)) s <- ifelse(!is.na(prog), paste0(s, ',"program_ch99":"', prog, '"'), s)
    if (!is.null(extra)) s <- paste0(s, extra)  # pre-rendered ',"k":v' fragments or ''
    s <- paste0(s, '}')
    out <- rep('', length(status))
    out[keep] <- paste0(if (first) '' else ',', s[keep])
    out
  }

  # base slot carries the full MFN-tier trace: the effective applied rate, the
  # statutory MFN (Column 1 General), the preference share bridging them, and the
  # data source — so the frontend can EXPLAIN why a country's base differs from
  # the headline MFN. Always present, first in the object (no leading comma).
  fb <- paste0(
    '"base":{"status":"active","reason":"', base_reason, '"',
    ifelse(base_rate > EPS, paste0(',"applied":', fmt(base_rate)), ''),
    ifelse(statutory_base > EPS & abs(statutory_base - base_rate) > EPS,
           paste0(',"statutory":', fmt(statutory_base)), ''),
    ifelse(base_pref_share > 0.005, paste0(',"preference_share":', fmt(base_pref_share)), ''),
    ifelse(!is.na(base_source), paste0(',"preference_source":"', base_source, '"'), ''),
    '}'
  )
  # 232 extras: legal duty basis (declared metal-content value vs full entered
  # value), the metal it attaches to, and the posted statutory rate when it
  # differs from the applied AVE. The frontend determination layer reads these
  # instead of inferring the basis from trigger heuristics.
  basis232 <- chr('duty_basis_232')
  stat232  <- num('statutory_rate_232')
  basis_metal_232 <- dplyr::coalesce(s232_metal, deriv)
  extra232 <- paste0(
    ifelse(!is.na(basis232), paste0(',"basis":"', basis232, '"'), ''),
    ifelse(!is.na(basis232) & basis232 == 'metal_content_value' & !is.na(basis_metal_232),
           paste0(',"basis_metal":"', basis_metal_232, '"'), ''),
    ifelse(stat232 > EPS & abs(stat232 - r232) > EPS,
           paste0(',"statutory":', fmt(stat232)), '')
  )
  f232  <- frag('232', s232_status, s232_reason, applied = r232, prog = c232,
                extra = extra232)
  f301  <- frag('301', s301_status, s301_reason, applied = r301, prog = c301)
  frec  <- frag('ieepa_recip', ie_status, ie_reason, applied = rrec,
                counterfactual = ie_cf, prog = ie_prog)
  ffent <- frag('ieepa_fent', fent_status, fent_reason, applied = rfent, prog = cfent)
  fs122 <- frag('s122', s122_status, s122_reason, applied = rs122, prog = cs122)
  f201  <- frag('section_201', s201_status, s201_reason, applied = r201, prog = cs201)

  rates$duty_provenance_json <- paste0('{', fb, f232, f301, frec, ffent, fs122, f201, '}')

  # ===========================================================================
  # ch99_rules_json — per-line Chapter 99 rule objects (additive column)
  # ===========================================================================
  # A JSON ARRAY of rule objects per line, the multi-code companion to the
  # one-code-per-authority scalar columns. Vocabulary aligns with the upstream
  # AuthoritySpec migration so the models stay convergeable:
  #   status:         applied | exempt_or_replaced | not_applicable |
  #                   potentially_applicable_requires_more_facts
  #   rate_type:      surcharge | floor_static | floor_post_mfn | passthrough
  #   stacking_class: primary_metal | primary_full | content_split | additive
  # Citations are reason codes resolved against config/duty_citations.yaml.
  # 9902/9904 candidates come from parse_chapter99_other() trigger matching.
  jesc <- function(x) gsub('"', '\\\\"', x)
  rule_frag <- function(code, authority, program, status, statutory = NULL,
                        rate_type = NULL, stacking_class = NULL, basis = NULL,
                        basis_metal = NULL, req_inputs = NULL,
                        stack_cite = NULL, basis_cite = NULL, keep) {
    # Recycle every arg to length n: ifelse() with a length-1 condition would
    # otherwise collapse the fragment vector to one element.
    code <- rep_len(code, n); authority <- rep_len(authority, n)
    program <- rep_len(program, n); status <- rep_len(status, n)
    if (!is.null(statutory)) statutory <- rep_len(statutory, n)
    if (!is.null(rate_type)) rate_type <- rep_len(rate_type, n)
    if (!is.null(stacking_class)) stacking_class <- rep_len(stacking_class, n)
    if (!is.null(basis)) basis <- rep_len(basis, n)
    if (!is.null(basis_metal)) basis_metal <- rep_len(basis_metal, n)
    if (!is.null(req_inputs)) req_inputs <- rep_len(req_inputs, n)
    if (!is.null(stack_cite)) stack_cite <- rep_len(stack_cite, n)
    if (!is.null(basis_cite)) basis_cite <- rep_len(basis_cite, n)
    s <- paste0(',{"ch99_code":',
                ifelse(is.na(code), 'null', paste0('"', code, '"')),
                ',"authority":"', authority, '"',
                ',"program":"', program, '"',
                ',"status":"', status, '"')
    if (!is.null(statutory)) {
      s <- ifelse(!is.na(statutory) & statutory > EPS,
                  paste0(s, ',"statutory_rate":', fmt(statutory)), s)
    }
    if (!is.null(rate_type)) {
      s <- ifelse(!is.na(rate_type), paste0(s, ',"rate_type":"', rate_type, '"'), s)
    }
    if (!is.null(stacking_class)) {
      s <- ifelse(!is.na(stacking_class),
                  paste0(s, ',"stacking_class":"', stacking_class, '"'), s)
    }
    if (!is.null(basis)) {
      s <- ifelse(!is.na(basis), paste0(s, ',"duty_basis":"', basis, '"'), s)
    }
    if (!is.null(basis_metal)) {
      s <- ifelse(!is.na(basis_metal),
                  paste0(s, ',"basis_metal":"', basis_metal, '"'), s)
    }
    if (!is.null(req_inputs)) {
      s <- ifelse(!is.na(req_inputs) & nzchar(req_inputs),
                  paste0(s, ',"required_user_inputs":[', req_inputs, ']'), s)
    }
    if (!is.null(stack_cite)) {
      s <- ifelse(!is.na(stack_cite),
                  paste0(s, ',"stacking_citation":"', stack_cite, '"'), s)
    }
    if (!is.null(basis_cite)) {
      s <- ifelse(!is.na(basis_cite),
                  paste0(s, ',"basis_citation":"', basis_cite, '"'), s)
    }
    s <- paste0(s, '}')
    keep[is.na(keep)] <- FALSE
    out <- rep('', n)
    out[keep] <- s[keep]
    out
  }

  stat301  <- num('statutory_rate_301')
  statrec  <- num('statutory_rate_ieepa_recip')
  statfent <- num('statutory_rate_ieepa_fent')
  stats122 <- num('statutory_rate_s122')
  stat201  <- num('statutory_rate_section_201')

  # Section 232: basis-aware. Metal-content-value rows carry the required
  # entry facts (CBP two-line reporting needs declared content value + kg;
  # aluminum also smelt/cast countries).
  is_metal_basis <- !is.na(basis232) & basis232 == 'metal_content_value'
  req232 <- ifelse(
    is_metal_basis,
    paste0('"metal_content_value","metal_content_kg"',
           ifelse(!is.na(basis_metal_232) & basis_metal_232 == 'aluminum',
                  ',"primary_smelt_country","secondary_smelt_country","cast_country"', '')),
    ''
  )
  r232_rule <- rule_frag(
    c232, 'section_232', s232_reason, 'applied',
    statutory = pmax(stat232, r232),
    rate_type = ifelse(!is.na(s232_annex) & s232_annex == 'annex_3',
                       'floor_static', 'surcharge'),
    stacking_class = ifelse(is_metal_basis, 'primary_metal', 'primary_full'),
    basis = basis232,
    basis_metal = ifelse(is_metal_basis, basis_metal_232, NA_character_),
    req_inputs = req232,
    basis_cite = ifelse(is_metal_basis, 's232_basis_metal_content',
                        ifelse(!is.na(s232_annex), 's232_full_value_proc11021',
                               NA_character_)),
    keep = r232 > EPS & !is.na(s232_reason)
  )

  r301_rule <- rule_frag(
    c301, 'section_301', dplyr::coalesce(s301_reason, 's301_active'), 'applied',
    statutory = pmax(stat301, r301),
    rate_type = 'surcharge', stacking_class = 'additive',
    keep = r301 > EPS
  )

  rrec_rule <- rule_frag(
    ie_prog, 'ieepa_reciprocal', ie_reason, 'applied',
    statutory = pmax(statrec, rrec),
    rate_type = ifelse(!is.na(ci_type) & ci_type == 'floor',
                       'floor_post_mfn', 'surcharge'),
    stacking_class = 'content_split',
    keep = rrec > EPS & ie_status == 'active' & !is.na(ie_reason)
  )

  # Exempt IEEPA lines: the exemption becomes a citable rule of its own.
  # Exemption heading codes are a curated map (pending-verification entries
  # omitted rather than guessed): Annex II / ITA electronics claims report
  # under 9903.01.32.
  EXEMPT_HEADING <- c(annex_ii = '9903.01.32', ita = '9903.01.32')
  ie_exempt_code <- unname(EXEMPT_HEADING[ie_src])
  rrec_exempt_rule <- rule_frag(
    ie_exempt_code, 'ieepa_reciprocal', ie_reason, 'exempt_or_replaced',
    statutory = ie_cf,
    keep = ie_status == 'exempt' & !is.na(ie_reason)
  )

  rfent_rule <- rule_frag(
    cfent, 'ieepa_fentanyl', fent_reason, 'applied',
    statutory = pmax(statfent, rfent),
    rate_type = 'surcharge',
    stacking_class = ifelse(country == CTY_CHINA, 'additive', 'content_split'),
    keep = rfent > EPS & !is.na(fent_reason)
  )

  rs122_rule <- rule_frag(
    cs122, 'section_122', dplyr::coalesce(s122_reason, 's122_active'), 'applied',
    statutory = pmax(stats122, rs122),
    rate_type = 'surcharge', stacking_class = 'content_split',
    stack_cite = 's122_non232_portion_only',
    keep = rs122 > EPS
  )

  r201_rule <- rule_frag(
    cs201, 'section_201', dplyr::coalesce(s201_reason, 's201_active'), 'applied',
    statutory = pmax(stat201, r201),
    rate_type = 'surcharge', stacking_class = 'additive',
    keep = r201 > EPS
  )

  # §301 USTR exclusion-heading candidates (e.g. 9903.88.69). The heading
  # carries no rate; whether a specific product falls inside the exclusion's
  # product description — and whether the importer can claim it — are fact
  # questions, so the rule is emitted as requires-more-facts on rows where
  # §301 is actually applied. rate_301 is never modified (determination-first
  # divergence from upstream d839e402's coverage-share zeroing).
  excl_frag <- rep('', n)
  if (!is.null(s301_exclusions) && nrow(s301_exclusions) > 0 &&
      all(c('hts10', 'ch99_code') %in% names(s301_exclusions))) {
    agg_excl <- s301_exclusions %>%
      dplyr::distinct(hts10, ch99_code) %>%
      dplyr::arrange(hts10, ch99_code) %>%
      dplyr::mutate(frag = paste0(
        ',{"ch99_code":"', ch99_code, '"',
        ',"authority":"section_301"',
        ',"program":"s301_exclusion"',
        ',"status":"potentially_applicable_requires_more_facts"',
        ',"missing_facts":["product_description_match",',
        '"exclusion_claim_eligibility"]}'
      )) %>%
      dplyr::group_by(hts10) %>%
      dplyr::summarise(frag = paste0(frag, collapse = ''), .groups = 'drop')
    idx_excl <- match(hts10, agg_excl$hts10)
    excl_frag <- ifelse(is.na(idx_excl) | r301 <= EPS,
                        '', agg_excl$frag[idx_excl])
    excl_frag[is.na(excl_frag)] <- ''
  }

  # 9902 MTB / 9904 ag-safeguard candidates by inline-trigger prefix match.
  other_frag <- rep('', n)
  if (!is.null(ch99_other) && nrow(ch99_other) > 0 &&
      'trigger_hts' %in% names(ch99_other)) {
    cand <- ch99_other %>%
      dplyr::mutate(rate_text = dplyr::coalesce(rate_text, '')) %>%
      dplyr::select(ch99_code, subchapter, rate_text, trigger_hts) %>%
      tidyr::unnest(trigger_hts) %>%
      dplyr::filter(!is.na(trigger_hts), nchar(trigger_hts) >= 6) %>%
      dplyr::distinct()
    if (nrow(cand) > 0) {
      uh <- unique(hts10)
      hit_list <- vector('list', nrow(cand))
      for (k in seq_len(nrow(cand))) {
        m <- uh[startsWith(uh, cand$trigger_hts[k])]
        if (length(m) > 0) {
          hit_list[[k]] <- tibble(
            hts10 = m,
            ch99_code = cand$ch99_code[k],
            subchapter = cand$subchapter[k],
            rate_text = cand$rate_text[k]
          )
        }
      }
      hits <- dplyr::bind_rows(hit_list)
      if (nrow(hits) > 0) {
        hits <- hits %>%
          dplyr::distinct() %>%
          dplyr::mutate(frag = paste0(
            ',{"ch99_code":"', ch99_code, '"',
            ',"authority":"', subchapter, '"',
            ',"program":"', subchapter, '"',
            ',"status":"potentially_applicable_requires_more_facts"',
            ifelse(nzchar(rate_text),
                   paste0(',"rate_text":"', jesc(rate_text), '"'), ''),
            ',"missing_facts":[',
            ifelse(subchapter == 'mtb_9902',
                   '"product_description_match","validity_window"',
                   '"quota_category","quota_period","quota_fill_status"'),
            ']}'
          ))
        agg <- hits %>%
          dplyr::group_by(hts10) %>%
          dplyr::summarise(frag = paste0(frag, collapse = ''), .groups = 'drop')
        idx <- match(hts10, agg$hts10)
        other_frag <- ifelse(is.na(idx), '', agg$frag[idx])
      }
    }
  }

  rules_all <- paste0(r232_rule, r301_rule, excl_frag, rrec_rule,
                      rrec_exempt_rule, rfent_rule, rs122_rule, r201_rule,
                      other_frag)
  rules_all <- sub('^,', '', rules_all)
  rates$ch99_rules_json <- paste0('[', rules_all, ']')

  rates
}


# =============================================================================
# Stacking Rules
# =============================================================================

#' Apply tariff stacking rules (vectorized)
#'
#' Implements mutual-exclusion stacking (aligned with Tariff-ETRs):
#'
#'   China (232 > 0):  232 + recip*nonmetal + fentanyl + 301 + s122 + other
#'   China (no 232):   reciprocal + fentanyl + 301 + s122 + other
#'   Others (232 > 0): 232 + recip*nonmetal + fentanyl + s122 + other
#'   Others (no 232):  reciprocal + fentanyl + s122 + other
#'
#' Key rules:
#'   - 232 and IEEPA reciprocal are mutually exclusive (232 takes precedence)
#'   - Pre-annex: for derivative 232 products (metal_share < 1.0), IEEPA reciprocal
#'     applies to the non-metal portion of customs value
#'   - Post-annex (>= S232_ANNEXES$effective_date, 2026-04-06): the April 2026
#'     proclamation applies 232 to the full customs value. nonmetal_share is
#'     forced to 0 for annex-classified products (s232_annex != NA & rate_232 > 0),
#'     so IEEPA/S122/fentanyl contribute zero on post-annex 232 products.
#'   - Fentanyl stacks on 232 for all countries (separate IEEPA authority)
#'   - Section 301 only applies to China
#'   - Section 122 is scaled by nonmetal_share on 232 products (same treatment as
#'     IEEPA reciprocal). Pre-annex: pure-metal products (metal_share = 1.0) have
#'     nonmetal_share = 0; derivatives apply s122 to the non-metal portion.
#'     Post-annex: nonmetal_share = 0 for all annex-classified 232 products.
#'     For non-232 products, s122 stacks at full value.
#'
#' @param df Data frame with rate_232, rate_301, rate_ieepa_recip,
#'   rate_ieepa_fent, rate_s122, rate_other, metal_share, country columns
#' @param cty_china Census code for China (default: '5700')
#' @param stacking_method 'mutual_exclusion' (default, 232/IEEPA mutual exclusion)
#'   or 'tpc_additive' (all authorities stack additively, matching TPC methodology)
#' @return df with total_additional and total_rate recomputed
has_informative_per_type_shares <- function(df) {
  required <- c('steel_share', 'aluminum_share', 'copper_share')
  if (!all(required %in% names(df))) {
    return(FALSE)
  }
  any(
    coalesce(df$steel_share, 0) > 0 |
      coalesce(df$aluminum_share, 0) > 0 |
      coalesce(df$copper_share, 0) > 0
  )
}

apply_stacking_rules <- function(df, cty_china = '5700', stacking_method = 'mutual_exclusion') {
  # Ensure optional columns exist and have no NAs
  if (!'rate_s122' %in% names(df)) {
    df$rate_s122 <- 0
  } else {
    df$rate_s122[is.na(df$rate_s122)] <- 0
  }
  if (!'rate_section_201' %in% names(df)) {
    df$rate_section_201 <- 0
  } else {
    df$rate_section_201[is.na(df$rate_section_201)] <- 0
  }
  if (!'metal_share' %in% names(df)) {
    df$metal_share <- 1.0
  } else {
    df$metal_share[is.na(df$metal_share)] <- 1.0
  }
  # §301 forced labor (91 FR 47318). Note 52(a): products subject to these
  # headings "shall also be subject to any additional duty provided for in this
  # subchapter or in subchapter IV" — so it stacks ADDITIVELY on everything,
  # with no metal-content split. The note 52(b)-(k) carve-outs are applied as
  # exemptions when the rate is computed, not as a stacking adjustment.
  if (!'rate_s301fl' %in% names(df)) {
    df$rate_s301fl <- 0
  } else {
    df$rate_s301fl[is.na(df$rate_s301fl)] <- 0
  }
  # §301 Brazil (91 FR 45516). Note 50(a) stacks it additively on everything,
  # including the note-52 forced-labor §301 — Brazil is in both actions.
  if (!'rate_s301br' %in% names(df)) {
    df$rate_s301br <- 0
  } else {
    df$rate_s301br[is.na(df$rate_s301br)] <- 0
  }

  # TPC additive: all authorities stack with no mutual exclusion.
  # TPC confirmed (March 2026) they mostly agree with mutual exclusion between
  # 232 and IEEPA, with exceptions for copper (232 + CA/MX fentanyl) and
  # derivatives (IEEPA on non-metal portion). This mode is retained for
  # sensitivity analysis, not as a TPC-matching switch.
  if (stacking_method == 'tpc_additive') {
    return(
      df %>%
        mutate(
          total_additional = rate_232 + rate_ieepa_recip + rate_ieepa_fent +
            rate_301 + rate_s122 + rate_section_201 + rate_s301fl + rate_s301br + rate_other,
          total_rate = base_rate + total_additional
        )
    )
  }

  # Per-metal-type nonmetal_share: only count the metal types that have active
  # 232 programs covering this product. Steel chapters → steel_share, aluminum
  # chapters + derivatives → aluminum_share, copper → copper_share.
  # Steel derivatives (outside ch72-73) use steel_share; aluminum derivatives
  # (outside ch76) use aluminum_share. The deriv_type column (set by
  # apply_232_derivatives) determines which type applies.
  # IEEPA fills everything not claimed by the active 232 program's metal type.
  # Gate on informative shares (not just column presence): flat/CBO metal methods
  # zero-fill the per-type columns so bind_rows() stays stable across revisions,
  # but those zero-filled rows must not enter per-type stacking logic — doing so
  # would drive nonmetal_share to 1.0 on every 232 product under the flat method.
  has_per_type <- has_informative_per_type_shares(df)

  if (has_per_type) {
    # Determine which metal type is active per product based on chapter/product type.
    # Steel chapters: 72/73; aluminum chapters: 76; copper headings: flagged;
    # derivatives: per deriv_type column (steel or aluminum).
    has_copper_flag <- 'is_copper_heading' %in% names(df)
    has_deriv_type <- 'deriv_type' %in% names(df)
    df <- df %>%
      mutate(
        .ch2 = substr(hts10, 1, 2),
        .active_type_share = case_when(
          rate_232 > 0 & .ch2 %in% c('72', '73')              ~ steel_share,
          rate_232 > 0 & .ch2 == '76'                          ~ aluminum_share,
          rate_232 > 0 & has_copper_flag & is_copper_heading   ~ copper_share,
          rate_232 > 0 & has_deriv_type & deriv_type == 'steel'    ~ steel_share,
          rate_232 > 0 & has_deriv_type & deriv_type == 'aluminum' ~ aluminum_share,
          rate_232 > 0 & metal_share < 1.0                     ~ aluminum_share,  # fallback
          TRUE ~ 0
        ),
        nonmetal_share = if_else(rate_232 > 0 & .active_type_share > 0,
                                  1 - .active_type_share, 0)
      ) %>%
      select(-.ch2, -.active_type_share)
  } else {
    # Fallback: aggregate metal_share (backward compat for flat/cbo methods)
    df <- df %>%
      mutate(nonmetal_share = if_else(rate_232 > 0 & metal_share < 1.0, 1 - metal_share, 0))
  }

  # Post-annex override: the April 2026 proclamation applies Section 232 to the
  # full customs value, eliminating metal-content-based mutual exclusion. Products
  # with an annex classification (s232_annex != NA) get nonmetal_share = 0 so that
  # IEEPA/S122/fentanyl do not leak through on a phantom non-metal fraction.
  # Annex II products (rate_232 = 0, removed from scope) are excluded by the
  # rate_232 > 0 guard — they receive full IEEPA/S122 as non-232 products.
  if ('s232_annex' %in% names(df)) {
    df <- df %>%
      mutate(nonmetal_share = if_else(
        !is.na(s232_annex) & rate_232 > 0, 0, nonmetal_share
      ))
  }

  df <- df %>%
    mutate(
      total_additional = case_when(
        # China with 232: 232 + recip*nonmetal + fentanyl + 301 + s122*nonmetal + s201 + other
        country == cty_china & rate_232 > 0 ~
          rate_232 + rate_ieepa_recip * nonmetal_share + rate_ieepa_fent + rate_301 +
          rate_s122 * nonmetal_share + rate_section_201 + rate_s301fl + rate_s301br + rate_other,

        # China without 232: reciprocal + fentanyl + 301 + s122 + s201 + other
        country == cty_china ~
          rate_ieepa_recip + rate_ieepa_fent + rate_301 + rate_s122 + rate_section_201 +
          rate_s301fl + rate_s301br + rate_other,

        # Others with 232: 232 + recip*nonmetal + fent*nonmetal + s122*nonmetal + s201 + other
        # Fentanyl follows the same content-based split as reciprocal: 232 covers
        # the metal/copper content, fentanyl applies to the non-metal portion only.
        # For heading products (auto_parts, copper, autos), nonmetal_share ≈ 0.
        rate_232 > 0 ~
          rate_232 + rate_ieepa_recip * nonmetal_share + rate_ieepa_fent * nonmetal_share +
          rate_s122 * nonmetal_share + rate_section_201 + rate_s301fl + rate_s301br + rate_other,

        # Others without 232: reciprocal + fentanyl + s122 + s201 + other
        TRUE ~ rate_ieepa_recip + rate_ieepa_fent + rate_s122 + rate_section_201 +
          rate_s301fl + rate_s301br + rate_other
      ),
      total_rate = base_rate + total_additional
    ) %>%
    select(-nonmetal_share)
}


# =============================================================================
# Net Authority Decomposition (used by 08_weighted_etr, 09_daily_series)
# =============================================================================

#' Compute net authority contributions from snapshot rate columns
#'
#' Derives per-authority net contributions from the timeseries rate columns
#' using mutual-exclusion stacking rules. Net contributions sum to total_additional.
#'
#' @param df Data frame with rate_232, rate_301, rate_ieepa_recip,
#'   rate_ieepa_fent, rate_s122, rate_section_201, rate_other, metal_share, country columns
#' @param cty_china Census code for China (default: '5700')
#' @param stacking_method 'mutual_exclusion' (default) or 'tpc_additive'
#' @return df with net_232, net_ieepa, net_fentanyl, net_301, net_s122,
#'   net_section_201, net_other added
compute_net_authority_contributions <- function(df, cty_china = '5700',
                                                stacking_method = 'mutual_exclusion') {
  # Ensure optional columns exist (backwards compat with old snapshots)
  if (!'rate_s122' %in% names(df)) df$rate_s122 <- 0
  if (!'rate_section_201' %in% names(df)) df$rate_section_201 <- 0
  if (!'rate_other' %in% names(df)) df$rate_other <- 0
  if (!'metal_share' %in% names(df)) df$metal_share <- 1.0

  # TPC additive: all authorities contribute their full rate (no mutual exclusion)
  if (stacking_method == 'tpc_additive') {
    return(
      df %>%
        mutate(
          net_232 = rate_232,
          net_ieepa = rate_ieepa_recip,
          net_fentanyl = rate_ieepa_fent,
          net_301 = rate_301,
          net_s122 = rate_s122,
          net_section_201 = rate_section_201,
          net_other = rate_other
        )
    )
  }

  has_per_type <- has_informative_per_type_shares(df)

  if (has_per_type) {
    has_copper_flag <- 'is_copper_heading' %in% names(df)
    has_deriv_type <- 'deriv_type' %in% names(df)
    df <- df %>%
      mutate(
        .ch2 = substr(hts10, 1, 2),
        .active_type_share = case_when(
          rate_232 > 0 & .ch2 %in% c('72', '73')                    ~ steel_share,
          rate_232 > 0 & .ch2 == '76'                                ~ aluminum_share,
          rate_232 > 0 & has_copper_flag & is_copper_heading         ~ copper_share,
          rate_232 > 0 & has_deriv_type & deriv_type == 'steel'      ~ steel_share,
          rate_232 > 0 & has_deriv_type & deriv_type == 'aluminum'   ~ aluminum_share,
          rate_232 > 0 & metal_share < 1.0                           ~ aluminum_share,
          TRUE ~ 0
        ),
        nonmetal_share = if_else(rate_232 > 0 & .active_type_share > 0,
                                  1 - .active_type_share, 0)
      ) %>%
      select(-.ch2, -.active_type_share)
  } else {
    df <- df %>%
      mutate(nonmetal_share = if_else(rate_232 > 0 & metal_share < 1.0, 1 - metal_share, 0))
  }

  # Post-annex full-value override (mirrors apply_stacking_rules — see docstring there).
  if ('s232_annex' %in% names(df)) {
    df <- df %>%
      mutate(nonmetal_share = if_else(
        !is.na(s232_annex) & rate_232 > 0, 0, nonmetal_share
      ))
  }

  df %>%
    mutate(
      net_232 = if_else(rate_232 > 0, rate_232, 0),
      net_ieepa = if_else(rate_232 > 0, rate_ieepa_recip * nonmetal_share, rate_ieepa_recip),
      net_fentanyl = case_when(
        country == cty_china ~ rate_ieepa_fent,
        rate_232 > 0 ~ rate_ieepa_fent * nonmetal_share,
        TRUE ~ rate_ieepa_fent
      ),
      net_301 = if_else(country == cty_china, rate_301, 0),
      net_s122 = if_else(rate_232 > 0, rate_s122 * nonmetal_share, rate_s122),
      net_section_201 = rate_section_201,
      net_other = rate_other
    ) %>%
    select(-nonmetal_share)
}


# =============================================================================
# Consolidated Functions (deduplicated from 03, 04, 06)
# =============================================================================

#' Parse rate from Chapter 99 general field
#'
#' Handles Ch99-specific formats:
#'   "The duty provided in the applicable subheading + 25%"
#'   "The duty provided in the applicable subheading plus 7.5%"
#'   "25%"
#'
#' Distinct from parse_rate() which handles MFN product rates.
#'
#' @param general_text Text from the general field
#' @return Numeric rate (e.g., 0.25) or NA
parse_ch99_rate <- function(general_text) {
  if (is.null(general_text) || is.na(general_text) || general_text == '') {
    return(NA_real_)
  }

  patterns <- c(
    '\\+\\s*([0-9]+\\.?[0-9]*)%',              # + 25% or +25%
    'plus\\s+([0-9]+\\.?[0-9]*)%',             # plus 25%
    'duty of\\s+([0-9]+\\.?[0-9]*)%',          # a duty of 50%
    '^([0-9]+\\.?[0-9]*)%$'                    # just "25%"
  )

  for (pattern in patterns) {
    match <- str_match(general_text, regex(pattern, ignore_case = TRUE))
    if (!is.na(match[1, 2])) {
      return(as.numeric(match[1, 2]) / 100)
    }
  }

  return(NA_real_)
}


#' Classify Chapter 99 code into authority buckets
#'
#' Unified classifier that uses normalized authority names:
#'   section_122, section_232, section_301, ieepa_reciprocal, section_201, other
#'
#' @param ch99_code Chapter 99 subheading (e.g., "9903.88.15")
#' @return Authority bucket name
classify_authority <- function(ch99_code) {
  if (is.na(ch99_code) || ch99_code == '') return('unknown')

  parts <- str_split(ch99_code, '\\.')[[1]]
  if (length(parts) < 2) return('unknown')

  # Guard against malformed Ch99 codes in older USITC editions: e.g. the
  # 2021 basic/rev_1-3 archives contain a data typo "9903.89,61" (comma
  # instead of the 2nd period), so parts[2] = "89,61" and as.integer() -> NA.
  # Without this guard the downstream `if (middle == 3)` hard-crashes
  # parse_chapter99() ("missing value where TRUE/FALSE needed"). Treat any
  # non-numeric middle segment as unknown authority.
  middle <- suppressWarnings(as.integer(parts[2]))
  if (is.na(middle)) return('unknown')

  # Section 122: 9903.03.xx (Phase 3, post-SCOTUS blanket)
  if (middle == 3) {
    return('section_122')
  }

  # Section 301 (Trade Act of 1974) — two 2026 actions share subchapter 9903.05:
  #   9903.05.01-.09        Brazil digital trade / preferential tariffs / IP /
  #                         ethanol / deforestation (U.S. note 50, 91 FR 45516)
  #   9903.05.20-9903.06.21 forced labor, 60 economies (U.S. note 52,
  #                         91 FR 47318 + 91 FR 47717)
  # Both roll up to authority 'section_301' so the ETR decomposition keeps one
  # consistent §301 line; the specific programs stay distinguishable via their
  # own rate columns (rate_s301br / rate_s301fl) and ch99 codes.
  if (middle == 5 || middle == 6) {
    return('section_301')
  }

  # Section 232:
  #   9903.74.xx  — MHD vehicles (US Note 38)
  #   9903.76.xx  — Wood products / lumber / furniture (US Note 37)
  #   9903.78.xx  — Copper derivatives (US Note 19)
  #   9903.79.xx  — Semiconductors (US Note 39, effective 2026-01-16)
  #   9903.80-85  — Steel, aluminum, derivatives
  #   9903.94.xx  — Auto tariffs (US Note 25/33)
  if (middle == 74 || middle == 76 || middle == 78 || middle == 79 ||
      (middle >= 80 && middle <= 85) || middle == 94) {
    return('section_232')
  }

  # Section 301: 9903.86-89 (China tariffs) + 9903.91 (Biden 301) + 9903.92 (cranes)
  if ((middle >= 86 && middle <= 89) || middle == 91 || middle == 92) {
    return('section_301')
  }

  # IEEPA reciprocal: 9903.90 (China surcharges) + 9903.93/95/96
  if (middle == 90 || (middle >= 93 && middle <= 96 && middle != 94)) {
    return('ieepa_reciprocal')
  }

  # Section 201 (safeguards): 9903.40-45
  if (middle >= 40 && middle <= 45) {
    return('section_201')
  }

  return('other')
}


#' Extract a legal effective-date offset from a Ch99 description
#'
#' HTS revisions sometimes publish new Ch99 entries with descriptions that
#' specify a future legal effective date — e.g. 9903.94.01 was added at rev_6
#' (HTS effective 2025-03-12) with description text "...effective with respect
#' to entries on or after April 3, 2025...". The HTS metadata says rev_6 is
#' active, but the rate is not legally collectible until 2025-04-03. Treating
#' the rate as active on the HTS effective_date over-states ~$7B of chapter 87
#' duty in March 2025 (see upstream eval s232_auto_effective_date_2026-04-28).
#'
#' Pattern is stable across revisions: "on or after [Month] [Day], [Year]" with
#' full English month names. Returns the EARLIEST date across all matches (the
#' conservative gate). Errors via stop() if a matched phrase fails to parse —
#' a silent NA would re-introduce the pre-activation collection bug this gate
#' is meant to prevent.
#'
#' Mirrors upstream src/rate_schema.R::extract_effective_date_offset().
#'
#' @param description Ch99 description text (scalar character)
#' @return Date object, NA if no pattern matches or text is empty
extract_effective_date_offset <- function(description) {
  if (is.null(description) || length(description) == 0 ||
      is.na(description) || description == '') {
    return(as.Date(NA))
  }
  matches <- regmatches(
    description,
    gregexpr('on or after [A-Za-z]+ [0-9]{1,2}, [0-9]{4}',
             description, ignore.case = TRUE)
  )[[1]]
  if (length(matches) == 0) return(as.Date(NA))
  date_strs <- sub('^on or after ', '', matches, ignore.case = TRUE)
  # %B in as.Date expects title-case month names ("April"); normalize.
  date_strs <- vapply(date_strs, function(s) {
    parts <- strsplit(s, ' ', fixed = TRUE)[[1]]
    parts[1] <- paste0(toupper(substr(parts[1], 1, 1)),
                       tolower(substring(parts[1], 2)))
    paste(parts, collapse = ' ')
  }, character(1), USE.NAMES = FALSE)
  parsed <- as.Date(date_strs, format = '%B %d, %Y')
  if (any(is.na(parsed))) {
    bad <- date_strs[is.na(parsed)]
    stop('extract_effective_date_offset: failed to parse ',
         paste(shQuote(bad), collapse = ', '),
         ' from description: ', shQuote(description))
  }
  min(parsed)
}


#' Drop Ch99 entries that are not yet legally active for a given revision
#'
#' Filters `ch99_data` to remove rows whose `effective_date_offset` (extracted
#' by `extract_effective_date_offset()` during `parse_chapter99()`) is strictly
#' AFTER the revision's `effective_date`. Rows with NA offset (no future-date
#' phrase in the description) are always retained — those are active as of
#' their HTS publication. Backwards-compatible: cached ch99_<revision>.rds files
#' produced before this column existed flow through unchanged.
#'
#' Mirrors upstream src/rate_schema.R::filter_active_ch99().
#'
#' @param ch99_data Tibble from `parse_chapter99()` with `effective_date_offset`
#' @param revision_effective_date Date (or coercible) of the revision's HTS effective date
#' @return Filtered tibble; row count reported via message() when rows are dropped
filter_active_ch99 <- function(ch99_data, revision_effective_date) {
  if (is.null(ch99_data) || nrow(ch99_data) == 0) return(ch99_data)
  if (!'effective_date_offset' %in% names(ch99_data)) {
    # Backwards-compatible no-op for any cached ch99_<revision>.rds file
    # produced before this column existed.
    return(ch99_data)
  }
  rev_date <- as.Date(revision_effective_date)
  not_yet_active <- !is.na(ch99_data$effective_date_offset) &
                    ch99_data$effective_date_offset > rev_date
  if (any(not_yet_active)) {
    n_drop <- sum(not_yet_active)
    earliest <- min(ch99_data$effective_date_offset[not_yet_active])
    message('  Dropping ', n_drop, ' Ch99 entr', if (n_drop == 1) 'y' else 'ies',
            ' not yet legally active at ', rev_date,
            ' (earliest activation: ', earliest, ')')
    ch99_data <- ch99_data[!not_yet_active, , drop = FALSE]
  }
  ch99_data
}


#' Extract a Ch99 window END date from a heading description
#'
#' Counterpart to extract_effective_date_offset() for window END dates. Time-
#' bounded Ch99 headings state their window in the description — e.g. the §301
#' exclusion heading 9903.88.69: "Effective with respect to entries on or after
#' June 15, 2024 and through November 9, 2026, articles the product of
#' China...". Two phrasings occur, with different inclusivity:
#'   "through [Month D, YYYY]"      -> that date IS the last active day
#'   "on or before [Month D, YYYY]" -> that date IS the last active day
#'   "before [Month D, YYYY]"       -> last active day is the PRIOR day
#'     (e.g. 9903.88.68: "on or after June 1, 2023, and before June 15, 2024")
#'
#' Returns the LAST ACTIVE DAY, normalized across phrasings. Multiple matches
#' return the LATEST date (conservative: keeps the entry active through the
#' longest stated window; the mirror of the start extractor's min()). Errors
#' via stop() if a matched phrase fails to parse — silent NA would let an
#' expired heading appear perpetually active.
#'
#' Mirrors upstream src/rate_schema.R::extract_expiry_date_offset() (d839e402).
#'
#' @param description Ch99 description text (scalar character)
#' @return Date (last active day), NA if no expiry phrase or text is empty
extract_expiry_date_offset <- function(description) {
  if (is.null(description) || length(description) == 0 ||
      is.na(description) || description == '') {
    return(as.Date(NA))
  }
  matches <- regmatches(
    description,
    gregexpr('(through|on or before|before) [A-Za-z]+ [0-9]{1,2}, [0-9]{4}',
             description, ignore.case = TRUE)
  )[[1]]
  # "on or after" contains no expiry keyword so it never matches; "on or
  # before" is matched in full (the alternation is ordered longest-first so
  # the bare-"before" branch cannot shave it down to exclusive semantics).
  if (length(matches) == 0) return(as.Date(NA))
  exclusive <- grepl('^before ', matches, ignore.case = TRUE)
  date_strs <- sub('^(through|on or before|before) ', '', matches,
                   ignore.case = TRUE)
  # %B in as.Date expects title-case month names ("April"); normalize.
  date_strs <- vapply(date_strs, function(s) {
    parts <- strsplit(s, ' ', fixed = TRUE)[[1]]
    parts[1] <- paste0(toupper(substr(parts[1], 1, 1)),
                       tolower(substring(parts[1], 2)))
    paste(parts, collapse = ' ')
  }, character(1), USE.NAMES = FALSE)
  parsed <- as.Date(date_strs, format = '%B %d, %Y')
  if (any(is.na(parsed))) {
    bad <- date_strs[is.na(parsed)]
    stop('extract_expiry_date_offset: failed to parse ',
         paste(shQuote(bad), collapse = ', '),
         ' from description: ', shQuote(description))
  }
  last_active <- parsed - ifelse(exclusive, 1L, 0L)
  max(last_active)
}


#' Build §301 exclusion-heading candidates for one revision
#'
#' Joins the curated exclusion-heading registry
#' (resources/s301_exclusion_headings.csv) against the heading->HTS10 map
#' (resources/s301_exclusion_lines.csv), date-filtered to the revision. USTR
#' exclusion headings (e.g. 9903.88.69) carry NO rate — they are
#' description-scoped carve-outs from §301 duties while their window is in
#' force, and whether a product claims one is a FACT question. This fork
#' therefore emits them as 'potentially_applicable_requires_more_facts' rule
#' objects in ch99_rules_json (see attach_duty_provenance()) instead of
#' upstream d839e402's full-line zeroing; rate_301 is never modified.
#'
#' Window per heading = CSV validity_start/validity_end (curator overrides)
#' coalesced with the window stated in THIS revision's own heading text
#' (extract_effective_date_offset / extract_expiry_date_offset on ch99_data
#' descriptions — USTR extends windows over time, so the text is re-read per
#' revision). Gates:
#'   * 9903.88.21-.28 'PERMANENT CONDITIONAL' derived-rate carve-outs
#'     (US note 20(z)-(gg)) are NOT claimable product exclusions — skipped.
#'   * Headings with no verifiable window anywhere (registry NEEDS_REVIEW
#'     rows, all-NA) are skipped until a curator supplies the window.
#'   * The window must contain the revision's effective_date.
#'
#' @param ch99_data Tibble from parse_chapter99() (ch99_code, description).
#' @param effective_date The revision's effective date (Date or string).
#' @param headings_path Registry CSV path (default resources/).
#' @param lines_path Heading->HTS10 map CSV path (default resources/).
#' @return Tibble (hts10, ch99_code) of in-window exclusion candidates;
#'   zero-row tibble when none.
build_s301_exclusion_candidates <- function(ch99_data, effective_date,
                                            headings_path = here('resources', 's301_exclusion_headings.csv'),
                                            lines_path = here('resources', 's301_exclusion_lines.csv')) {
  empty <- tibble(hts10 = character(0), ch99_code = character(0))
  if (!file.exists(headings_path) || !file.exists(lines_path)) return(empty)
  if (is.null(ch99_data) || nrow(ch99_data) == 0) return(empty)

  registry <- suppressMessages(read_csv(headings_path, col_types = cols(
    ch99_code = col_character(), validity_start = col_date(),
    validity_end = col_date(), coverage_share = col_double(),
    .default = col_character()
  )))
  # Permanent conditional derived-rate carve-outs are not USTR product
  # exclusions — never emit them as claimable candidates.
  if ('source_note' %in% names(registry)) {
    registry <- registry %>%
      filter(is.na(source_note) |
               !grepl('PERMANENT CONDITIONAL', source_note, fixed = TRUE))
  }
  if (nrow(registry) == 0) return(empty)

  eff_d <- as.Date(effective_date)
  active <- ch99_data %>%
    filter(ch99_code %in% registry$ch99_code) %>%
    mutate(
      win_start = as.Date(vapply(description, function(d)
        as.character(extract_effective_date_offset(d)), character(1),
        USE.NAMES = FALSE)),
      win_end = as.Date(vapply(description, function(d)
        as.character(extract_expiry_date_offset(d)), character(1),
        USE.NAMES = FALSE))
    ) %>%
    distinct(ch99_code, win_start, win_end) %>%
    inner_join(registry %>% select(ch99_code, validity_start, validity_end),
               by = 'ch99_code') %>%
    mutate(
      win_start = coalesce(validity_start, win_start),
      win_end   = coalesce(validity_end,   win_end)
    ) %>%
    filter(!(is.na(win_start) & is.na(win_end)),   # unverifiable: skip
           is.na(win_start) | win_start <= eff_d,
           is.na(win_end)   | eff_d <= win_end)
  if (nrow(active) == 0) return(empty)

  lines <- suppressMessages(read_csv(lines_path, col_types = cols(
    ch99_code = col_character(), hts10 = col_character(),
    .default = col_character()
  )))
  out <- lines %>%
    filter(ch99_code %in% active$ch99_code) %>%
    distinct(hts10, ch99_code)
  if (nrow(out) > 0) {
    message('  Section 301 exclusion candidates: ', n_distinct(out$hts10),
            ' hts10 across ', n_distinct(out$ch99_code),
            ' in-window heading(s) at ', eff_d, ' (',
            paste(sort(unique(out$ch99_code)), collapse = ', '), ')')
  }
  out
}


#' Resolve the specific Chapter 99 code driving each authority rate
#'
#' For each row in `rates`, selects the best-fit 8-digit ch99_code per active
#' authority (232, 301, IEEPA reciprocal, IEEPA fentanyl, s122, s201) using the
#' revision's ch99_data plus extracted ieepa_rates and fentanyl_rates. Writes
#' results to columns: ch99_code_232, ch99_code_301, ch99_code_ieepa_recip,
#' ch99_code_ieepa_fent, ch99_code_s122, ch99_code_s201.
#'
#' Selection strategy per authority:
#'   - 232 derivatives: the product's own deriv_ch99_code (US Note 16/19
#'     subdivision membership carried from s232_derivative_products.csv by
#'     apply_232_derivatives) when active in this revision; otherwise the
#'     broadest active heading for that metal (most CSV products), logged.
#'   - 232 base: partitions by hts10 chapter/heading (72/73 steel, 76 aluminum,
#'     74 copper, 8703/8704/8708 auto, 44/94 wood, 8701/02/04/06 MHD); within a
#'     pool, the heading whose parsed rate uniquely matches the row's statutory
#'     232 rate; deterministic fallback is logged.
#'   - 301: first active 9903.88.xx code (China surcharges are monolithic per
#'     revision within a rate bucket; first active code is representative).
#'   - IEEPA reciprocal: country-specific via ieepa_rates census_code → ch99_code,
#'     falls back to 9903.01.25 (universal baseline) when country not listed.
#'   - IEEPA fentanyl: country-specific via fentanyl_rates (general entries only).
#'   - s122: first active 9903.03.xx code.
#'   - s201: first active 9903.40-45 code.
#'
#' @param rates Rates tibble with hts10, country, rate_*, deriv_type and
#'   (optionally) deriv_ch99_code columns
#' @param ch99_data Parsed Chapter 99 data with ch99_code column
#' @param ieepa_rates IEEPA reciprocal rates tibble (or NULL)
#' @param fentanyl_rates IEEPA fentanyl rates tibble (or NULL)
#' @param deriv_products Derivative product CSV tibble (hts_prefix, ch99_code,
#'   derivative_type) used to derive the active derivative heading sets
#' @return rates with ch99_code_* columns added
resolve_ch99_codes <- function(rates, ch99_data,
                                ieepa_rates = NULL,
                                fentanyl_rates = NULL,
                                deriv_products = NULL) {
  # Initialize all ch99_code_* columns to NA
  rates <- rates %>%
    mutate(
      ch99_code_232 = NA_character_,
      ch99_code_301 = NA_character_,
      ch99_code_ieepa_recip = NA_character_,
      ch99_code_ieepa_fent = NA_character_,
      ch99_code_s122 = NA_character_,
      ch99_code_s201 = NA_character_
    )

  if (is.null(ch99_data) || nrow(ch99_data) == 0 || !'ch99_code' %in% names(ch99_data)) {
    return(rates)
  }

  # Classify active ch99 codes by authority (unique set only)
  active_codes <- unique(ch99_data$ch99_code)
  active_codes <- active_codes[!is.na(active_codes)]
  if (length(active_codes) == 0) return(rates)
  code_authority <- vapply(active_codes, classify_authority, character(1))

  codes_232  <- active_codes[code_authority == 'section_232']
  codes_301  <- active_codes[code_authority == 'section_301']
  codes_s122 <- active_codes[code_authority == 'section_122']
  codes_s201 <- active_codes[code_authority == 'section_201']

  # ---- Section 232 ----
  if ('rate_232' %in% names(rates) && length(codes_232) > 0) {
    # Derivative heading sets come from the reviewed product CSV (per-product
    # ch99_code = US Note 16/19 subdivision membership), not hardcoded lists.
    deriv_sets <- if (!is.null(deriv_products) && nrow(deriv_products) > 0 &&
                      all(c('ch99_code', 'derivative_type') %in% names(deriv_products))) {
      deriv_products %>%
        filter(!is.na(ch99_code)) %>%
        count(derivative_type, ch99_code, name = 'n_products')
    } else {
      tibble(derivative_type = character(0), ch99_code = character(0),
             n_products = integer(0))
    }
    alum_deriv  <- intersect(
      deriv_sets$ch99_code[deriv_sets$derivative_type == 'aluminum'], codes_232)
    steel_deriv <- intersect(
      deriv_sets$ch99_code[deriv_sets$derivative_type == 'steel'], codes_232)
    steel_base  <- codes_232[grepl('^9903\\.(80|81|82|83|84)\\.', codes_232) & !codes_232 %in% steel_deriv]
    alum_base   <- codes_232[grepl('^9903\\.85\\.', codes_232) & !codes_232 %in% alum_deriv]
    copper_base <- codes_232[grepl('^9903\\.78\\.', codes_232)]
    auto_base   <- codes_232[grepl('^9903\\.94\\.', codes_232)]
    wood_base   <- codes_232[grepl('^9903\\.76\\.', codes_232)]
    mhd_base    <- codes_232[grepl('^9903\\.74\\.', codes_232)]

    default_232 <- sort(codes_232)[1]

    # Fallback for derivative rows with no usable product-level code: the
    # broad catch-all heading of that metal = the active heading covering
    # the most CSV products (e.g. Note 19(k) -> 9903.85.08), never sort()[1].
    pick_broadest <- function(type) {
      pool <- deriv_sets[deriv_sets$derivative_type == type &
                           deriv_sets$ch99_code %in% codes_232, ]
      if (nrow(pool) == 0) return(NA_character_)
      pool$ch99_code[which.max(pool$n_products)]
    }

    deriv_col <- if ('deriv_type' %in% names(rates)) {
      rates$deriv_type
    } else {
      rep(NA_character_, nrow(rates))
    }
    deriv_code_col <- if ('deriv_ch99_code' %in% names(rates)) {
      rates$deriv_ch99_code
    } else {
      rep(NA_character_, nrow(rates))
    }

    chapter <- substr(rates$hts10, 1, 2)
    heading <- substr(rates$hts10, 1, 4)

    pick <- rep(NA_character_, nrow(rates))

    # Derivatives take precedence. The product's own subdivision heading wins
    # whenever it is active in this revision; otherwise fall back to the
    # broadest active heading for that metal (pre-March-2025 revisions where
    # e.g. 9903.85.08 did not exist yet) and count the fallbacks.
    mask_alum_deriv  <- !is.na(deriv_col) & deriv_col == 'aluminum'
    mask_steel_deriv <- !is.na(deriv_col) & deriv_col == 'steel'
    prod_code_ok <- !is.na(deriv_code_col) & deriv_code_col %in% codes_232
    pick[mask_alum_deriv & prod_code_ok]  <- deriv_code_col[mask_alum_deriv & prod_code_ok]
    pick[mask_steel_deriv & prod_code_ok] <- deriv_code_col[mask_steel_deriv & prod_code_ok]

    fb_alum  <- coalesce(pick_broadest('aluminum'), default_232)
    fb_steel <- coalesce(pick_broadest('steel'),    default_232)
    n_fb_alum  <- sum(mask_alum_deriv & is.na(pick) & rates$rate_232 > 0)
    n_fb_steel <- sum(mask_steel_deriv & is.na(pick) & rates$rate_232 > 0)
    pick[mask_alum_deriv & is.na(pick)]  <- fb_alum
    pick[mask_steel_deriv & is.na(pick)] <- fb_steel
    if (n_fb_alum + n_fb_steel > 0) {
      message('  ch99_code_232: ', n_fb_alum, ' aluminum + ', n_fb_steel,
              ' steel derivative rows used the broad-heading fallback (',
              fb_alum, ' / ', fb_steel, ') — product-level code absent or ',
              'not active in this revision')
    }

    # Chapter/heading-based base 232. Within a pool, match the row's
    # statutory rate to the heading whose parsed rate equals it (unique
    # matches only); deterministic first-sorted fallback with a log line.
    stat_232 <- if ('statutory_rate_232' %in% names(rates)) {
      coalesce(rates$statutory_rate_232, rates$rate_232)
    } else {
      rates$rate_232
    }
    ch99_rate_lookup <- ch99_data %>%
      filter(!is.na(ch99_code), !is.na(rate)) %>%
      distinct(ch99_code, rate) %>%
      mutate(rate = round(rate, 6))

    pick_base <- function(mask, pool_codes, label) {
      mask <- mask & is.na(pick)
      if (!any(mask) || length(pool_codes) == 0) return(invisible(NULL))
      if (length(pool_codes) == 1) {
        pick[mask] <<- pool_codes
        return(invisible(NULL))
      }
      rate_map <- ch99_rate_lookup %>%
        filter(ch99_code %in% pool_codes) %>%
        group_by(rate) %>% filter(n() == 1) %>% ungroup()
      matched <- rate_map$ch99_code[match(round(stat_232[mask], 6), rate_map$rate)]
      fallback <- sort(pool_codes)[1]
      n_fb <- sum(is.na(matched) & rates$rate_232[mask] > 0)
      if (n_fb > 0) {
        message('  ch99_code_232 base (', label, '): ', n_fb,
                ' rows had no unique rate match; using ', fallback)
      }
      pick[mask] <<- coalesce(matched, fallback)
      invisible(NULL)
    }

    pick_base(chapter %in% c('72', '73'),               steel_base,  'steel')
    pick_base(chapter == '76',                          alum_base,   'aluminum')
    pick_base(chapter == '74',                          copper_base, 'copper')
    pick_base(heading %in% c('8703', '8704', '8708'),   auto_base,   'auto')
    pick_base(chapter %in% c('44', '94'),               wood_base,   'wood')
    pick_base(heading %in% c('8701', '8702', '8704', '8706'), mhd_base, 'mhd')

    # Fallback: any active 232 code (last resort, logged)
    n_default <- sum(is.na(pick) & rates$rate_232 > 0)
    if (n_default > 0) {
      message('  ch99_code_232: ', n_default, ' rated rows fell through to ',
              'default ', default_232)
    }
    pick[is.na(pick)] <- default_232

    rates$ch99_code_232 <- if_else(rates$rate_232 > 0, pick, NA_character_)
  }

  # ---- Section 301 ----
  if ('rate_301' %in% names(rates) && length(codes_301) > 0) {
    rates$ch99_code_301 <- if_else(rates$rate_301 > 0, sort(codes_301)[1], NA_character_)
  }

  # ---- IEEPA reciprocal (country-specific) ----
  if ('rate_ieepa_recip' %in% names(rates)) {
    recip_map <- NULL
    if (!is.null(ieepa_rates) && nrow(ieepa_rates) > 0 &&
        all(c('ch99_code', 'census_code') %in% names(ieepa_rates))) {
      recip_map <- ieepa_rates %>%
        filter(!is.na(census_code), !is.na(ch99_code), !is.na(rate)) %>%
        arrange(desc(rate)) %>%
        group_by(census_code) %>%
        summarise(.recip_code = first(ch99_code), .groups = 'drop') %>%
        rename(country = census_code)
    }
    if (!is.null(recip_map) && nrow(recip_map) > 0) {
      rates <- rates %>% left_join(recip_map, by = 'country')
    } else {
      rates$.recip_code <- NA_character_
    }
    rates <- rates %>%
      mutate(
        ch99_code_ieepa_recip = if_else(
          rate_ieepa_recip > 0,
          coalesce(.recip_code, '9903.01.25'),
          NA_character_
        )
      ) %>%
      select(-.recip_code)
  }

  # ---- IEEPA fentanyl (country-specific) ----
  if ('rate_ieepa_fent' %in% names(rates)) {
    fent_map <- NULL
    if (!is.null(fentanyl_rates) && nrow(fentanyl_rates) > 0 &&
        all(c('ch99_code', 'census_code') %in% names(fentanyl_rates))) {
      has_entry_type <- 'entry_type' %in% names(fentanyl_rates)
      fent_map <- fentanyl_rates %>%
        { if (has_entry_type) filter(., entry_type == 'general') else . } %>%
        filter(!is.na(census_code), !is.na(ch99_code), !is.na(rate)) %>%
        arrange(desc(rate)) %>%
        group_by(census_code) %>%
        summarise(.fent_code = first(ch99_code), .groups = 'drop') %>%
        rename(country = census_code)
    }
    if (!is.null(fent_map) && nrow(fent_map) > 0) {
      rates <- rates %>%
        left_join(fent_map, by = 'country') %>%
        mutate(
          ch99_code_ieepa_fent = if_else(rate_ieepa_fent > 0, .fent_code, NA_character_)
        ) %>%
        select(-.fent_code)
    }
  }

  # ---- Section 122 ----
  if ('rate_s122' %in% names(rates) && length(codes_s122) > 0) {
    rates$ch99_code_s122 <- if_else(rates$rate_s122 > 0, sort(codes_s122)[1], NA_character_)
  }

  # ---- Section 201 ----
  if ('rate_section_201' %in% names(rates) && length(codes_s201) > 0) {
    rates$ch99_code_s201 <- if_else(rates$rate_section_201 > 0, sort(codes_s201)[1], NA_character_)
  }

  rates
}


#' Check if HTS code is a valid 10-digit product code
#'
#' @param hts_code HTS code (with or without dots)
#' @return Logical
is_valid_hts10 <- function(hts_code) {
  if (is.null(hts_code) || is.na(hts_code) || hts_code == '') {
    return(FALSE)
  }

  clean <- gsub('\\.', '', hts_code)
  nchar(clean) == 10 && grepl('^[0-9]+$', clean)
}


# =============================================================================
# Blanket Tariff Expansion Helper
# =============================================================================

#' Add product-country pairs not yet in rates for a blanket tariff
#'
#' Common pattern used by fentanyl, 232 derivatives, and other blanket tariffs:
#' expand covered products x applicable countries, anti-join against existing
#' rows in rates, assign the blanket rate, and bind to rates.
#'
#' @param rates Current rates tibble
#' @param products Product data with hts10, base_rate columns
#' @param covered_hts10 Character vector of HTS10 codes subject to this tariff
#' @param country_rates Tibble with 'country' and 'blanket_rate' columns
#' @param rate_col Name of the rate column to set (e.g., 'rate_ieepa_fent')
#' @param label Description for log message (e.g., 'fentanyl-only duties')
#' @return Updated rates tibble with new pairs added
add_blanket_pairs <- function(rates, products, covered_hts10, country_rates,
                              rate_col, label) {
  applicable <- country_rates %>% filter(blanket_rate > 0) %>% pull(country)
  if (length(applicable) == 0 || length(covered_hts10) == 0) return(rates)

  existing <- rates %>%
    filter(hts10 %in% covered_hts10, country %in% applicable) %>%
    select(hts10, country)

  new_pairs <- products %>%
    filter(hts10 %in% covered_hts10) %>%
    select(hts10, base_rate) %>%
    mutate(base_rate = coalesce(base_rate, 0)) %>%
    tidyr::expand_grid(country = applicable) %>%
    anti_join(existing, by = c('hts10', 'country')) %>%
    left_join(country_rates, by = 'country') %>%
    # Zero-fill from the single source of truth: a hardcoded list here silently
    # left any newly added authority column as NA on blanket-added pairs.
    zero_fill_authority_rates()

  new_pairs[[rate_col]] <- new_pairs$blanket_rate
  new_pairs <- new_pairs %>%
    filter(blanket_rate > 0) %>%
    select(-blanket_rate)

  if (nrow(new_pairs) > 0) {
    message('  Adding ', nrow(new_pairs), ' product-country pairs for ', label)
    rates <- bind_rows(rates, new_pairs)
  }

  return(rates)
}


# =============================================================================
# Chapter 99 Source Registry
# =============================================================================

#' Load the Chapter 99 program/source registry
#'
#' Reviewed config mapping every program family to its legal sources (Federal
#' Register, CBP CSMS, FAQs, quota bulletins) plus the rule-object field list
#' and sweep algorithm. Drives: (i) QC expected program families per revision
#' era, (ii) citation URLs in the rules emit, (iii) the coverage roadmap.
#' See config/ch99_source_registry.yaml (source: SAIL legal review 2026-06-11).
#'
#' @param path Path to ch99_source_registry.yaml
#' @return Parsed registry list, or NULL if missing
load_ch99_source_registry <- function(path = here('config', 'ch99_source_registry.yaml')) {
  if (!file.exists(path)) {
    message('  Chapter 99 source registry not found: ', path)
    return(NULL)
  }
  yaml::read_yaml(path)
}


# =============================================================================
# Section 232 Derivative Products
# =============================================================================

#' Load Section 232 derivative product list
#'
#' Reads the derivative product CSV containing both aluminum derivatives
#' (outside ch76, covered by 9903.85.04/.07/.08, US Note 19) and steel
#' derivatives (outside ch72-73, covered by 9903.81.89-93, US Note 16).
#' Steel derivatives added via Section 232 Inclusions Process (FR 2025-15819).
#' Cannot be extracted from HTS JSON.
#'
#' @param path Path to s232_derivative_products.csv
#' @param effective_date Optional date to filter entries by effective_date column.
#'   Only entries with effective_date <= this date (or blank) are returned.
#' @return Tibble with hts_prefix, ch99_code, derivative_type, effective_date; or NULL if missing
load_232_derivative_products <- function(path = here('resources', 's232_derivative_products.csv'),
                                         effective_date = NULL) {
  if (!file.exists(path)) {
    message('  232 derivative products file not found: ', path)
    return(NULL)
  }

  products <- read_csv(path, col_types = cols(
    hts_prefix = col_character(),
    ch99_code = col_character(),
    derivative_type = col_character(),
    effective_date = col_date(format = '')
  ))

  # Filter by effective_date if provided
  if (!is.null(effective_date) && 'effective_date' %in% names(products)) {
    n_before <- nrow(products)
    products <- products %>%
      filter(is.na(effective_date) | effective_date <= !!effective_date)
    n_filtered <- n_before - nrow(products)
    if (n_filtered > 0) {
      message('  Filtered out ', n_filtered, ' derivative entries not yet effective at ', effective_date)
    }
  }

  message('  Loaded ', nrow(products), ' Section 232 derivative product prefixes')
  return(products)
}


#' Resolve a SINGLE country name captured from Chapter 99 heading text
#'
#' Deliberately separate from extract_country_names(), which scans free text for
#' ALL country substrings (used for "except products of A, B, C" exemption lists).
#' Substring-scanning 240 census names would produce false hits — "Niger" inside
#' "Nigeria", "India" inside "British Indian Ocean Territory" — so a captured
#' single name gets exact/aliased resolution instead.
#'
#' Backed by resources/census_codes.csv (all 240 origins) rather than a hardcoded
#' map, so new economies resolve without a code change. Returns CENSUS codes;
#' check_country_applies() accepts either census or ISO.
#'
#' @param name Character scalar, e.g. "Kazakhstan", "the Philippines", "Türkiye"
#' @return Character vector of census codes (length 0 if unresolvable)
resolve_country_name <- function(name) {
  if (is.null(name) || length(name) == 0 || is.na(name) || !nzchar(trimws(name))) {
    return(character(0))
  }

  # Try the WHOLE phrase first. This must precede any splitting, because " and "
  # is part of many country names — "Bosnia and Herzegovina", "Trinidad and
  # Tobago", "Antigua and Barbuda", "Saint Kitts and Nevis". Splitting first
  # would shred them into unresolvable fragments.
  whole <- .resolve_one_country(name)
  if (length(whole) > 0) return(whole)

  # Chapter 99 rate lines routinely name two origins on one heading, e.g.
  # "articles the product of Cameroon or the Democratic Republic of the Congo".
  # Only " or " (and commas) separate distinct origins in this corpus; " and " is
  # deliberately NOT a separator, per the names above.
  parts <- unlist(strsplit(name, '\\s+or\\s+|,\\s*', perl = TRUE))
  parts <- trimws(parts)
  parts <- parts[nzchar(parts)]
  if (length(parts) <= 1) return(character(0))

  out <- character(0)
  for (part in parts) {
    codes <- .resolve_one_country(part)
    # Fail CLOSED on a partial resolution: silently applying a two-origin duty
    # to only one origin is a wrong number that looks right. Returning nothing
    # makes parse_countries() report 'unknown', which the Ch99 completeness gate
    # surfaces when the heading carries a rate.
    if (length(codes) == 0) return(character(0))
    out <- c(out, codes)
  }
  unique(out)
}


# Resolve one country name to census code(s). 'European Union' expands to EU27.
.resolve_one_country <- function(name) {
  lookup <- .census_name_lookup()
  norm <- normalize_country_name(name)
  if (!nzchar(norm)) return(character(0))
  # A split part can retain the article, e.g. "Cameroon or THE Democratic
  # Republic of the Congo" -> "the democratic republic of the congo".
  norm <- sub('^the\\s+', '', norm)
  if (!nzchar(norm)) return(character(0))

  # The EU is named as a bloc on several reciprocal headings.
  if (norm %in% c('european union', 'eu', 'member state of the european union',
                  'a member state of the european union')) {
    eu <- tryCatch(load_policy_params()$EU27_CODES, error = function(e) NULL)
    return(if (length(eu) > 0) as.character(eu) else character(0))
  }

  # HTS spellings that differ from the Census list. normalize_country_name()
  # strips non-ASCII and punctuation, so accented/apostrophised names arrive
  # mangled: "Côte d'Ivoire" -> "cte divoire", "Türkiye" -> "trkiye".
  aliases <- c(
    'trkiye'                          = 'turkey',
    'turkiye'                         = 'turkey',
    'cte divoire'                     = 'cote divoire',
    'cte divoire'                     = 'cote divoire',
    'ivory coast'                     = 'cote divoire',
    'south korea'                     = 'south korea republic of korea',
    'republic of korea'               = 'south korea republic of korea',
    'north korea'                     = 'north korea democratic peoples republic of korea',
    'russian federation'              = 'russia',
    'myanmar'                         = 'burma myanmar',
    'myanmar burma'                   = 'burma myanmar',
    'burma'                           = 'burma myanmar',
    'democratic republic of the congo' = 'congo democratic republic of the congo',
    'republic of the congo'           = 'congo republic of the congo',
    'czechia'                         = 'czech republic',
    'cabo verde'                      = 'cape verde',
    'east timor'                      = 'timorleste'
  )
  if (norm %in% names(aliases)) norm <- unname(aliases[norm])

  hit <- lookup$code[match(norm, lookup$norm_name)]
  if (!is.na(hit)) return(hit)

  # Census names often carry a parenthetical gloss that the HTS omits, e.g.
  # "Falkland Islands (Islas Malvinas)", "Syria (Syrian Arab Republic)". A single
  # unambiguous prefix match resolves those; ambiguity fails closed.
  cand <- lookup$code[startsWith(lookup$norm_name, norm)]
  if (length(cand) == 1) return(cand)

  character(0)
}


# Cached normalized Census name -> code lookup (240 origins).
.census_name_lookup_cache <- NULL
.census_name_lookup <- function() {
  if (!is.null(.census_name_lookup_cache)) return(.census_name_lookup_cache)
  path <- here('resources', 'census_codes.csv')
  if (!file.exists(path)) {
    return(tibble(norm_name = character(0), code = character(0)))
  }
  tbl <- read_csv(path, col_types = cols(Code = col_character(),
                                         Name = col_character())) %>%
    transmute(norm_name = normalize_country_name(Name), code = Code) %>%
    filter(nzchar(norm_name)) %>%
    distinct(norm_name, .keep_all = TRUE)
  # Fold in the curated GN-name aliases already maintained in the repo.
  apath <- here('resources', 'country_name_aliases.csv')
  if (file.exists(apath)) {
    al <- read_csv(apath, col_types = cols(.default = col_character())) %>%
      transmute(norm_name = normalize_country_name(gn_name), code = census_code) %>%
      filter(nzchar(norm_name))
    tbl <- bind_rows(tbl, al) %>% distinct(norm_name, .keep_all = TRUE)
  }
  .census_name_lookup_cache <<- tbl
  tbl
}


#' Resolve per-country Section 301 forced-labor tier rates
#'
#' USTR imposed four distinct tiers (91 FR 47318). Two are FLAT additional ad
#' valorem rates; the other two are TOTAL-DUTY CAPS, where the additional duty is
#' whatever brings the total to the cap — max(0, cap - base_rate), the same shape
#' as the annex_3 floor. Conflating them would overcharge every capped economy by
#' its MFN rate.
#'
#' @param countries Character vector of census country codes
#' @param fl_cfg policy_params$SECTION_301_FORCED_LABOR
#' @return Tibble with country, fl_rate, fl_is_cap
s301fl_country_tiers <- function(countries, fl_cfg) {
  empty <- tibble(country = character(0), fl_rate = numeric(0), fl_is_cap = logical(0))
  if (is.null(fl_cfg)) return(empty)

  r10  <- as.numeric(fl_cfg$rate_10  %||% 0.10)
  r125 <- as.numeric(fl_cfg$rate_12_5 %||% 0.125)

  tiers <- bind_rows(
    tibble(country = as.character(fl_cfg$tier_10pct         %||% character(0)),
           fl_rate = r10,  fl_is_cap = FALSE),
    tibble(country = as.character(fl_cfg$tier_10pct_net_mfn %||% character(0)),
           fl_rate = r10,  fl_is_cap = TRUE),
    tibble(country = as.character(fl_cfg$tier_12_5pct       %||% character(0)),
           fl_rate = r125, fl_is_cap = FALSE),
    tibble(country = as.character(fl_cfg$tier_12_5pct_net_mfn %||% character(0)),
           fl_rate = r125, fl_is_cap = TRUE)
  )
  if (nrow(tiers) == 0) return(empty)

  # A country in two tiers is a config defect — the notice assigns exactly one.
  dup <- tiers$country[duplicated(tiers$country)]
  if (length(dup) > 0) {
    warning('s301fl_country_tiers: country in multiple tiers (config defect): ',
            paste(unique(dup), collapse = ', '))
    tiers <- tiers %>% distinct(country, .keep_all = TRUE)
  }

  tiers %>% filter(country %in% countries)
}


#' Load and normalize the Section 301 forced-labor exemption annexes
#'
#' Annex I (common) conditions: full/ex = unconditional; aircraft/pharma =
#' USE-conditional (share-scaled by the caller). Annex II (per-country)
#' conditions: full = unconditional; fta = preference-conditional. The `countries`
#' column of Annex II is `;`-separated (e.g. the 27 EU census origins, or the six
#' CAFTA-DR origins on one row), so it is exploded to one row per country.
#'
#' @param fl_cfg policy_params$SECTION_301_FORCED_LABOR
#' @return list(common = tibble(hts8, condition), country = tibble(country, hts8, condition))
load_s301fl_exemptions <- function(fl_cfg) {
  out <- list(common = tibble(hts8 = character(0), condition = character(0)),
              country = tibble(country = character(0), hts8 = character(0),
                               condition = character(0)))
  if (is.null(fl_cfg)) return(out)

  cpath <- fl_cfg$common_exemptions
  if (!is.null(cpath)) {
    cpath <- if (file.exists(cpath)) cpath else here(cpath)
    if (file.exists(cpath)) {
      out$common <- read_csv(cpath, col_types = cols(.default = col_character())) %>%
        transmute(hts8 = hts_code,
                  # 'ex' (an ex-line carve-out) is treated as a full exemption,
                  # matching the annex builder.
                  condition = if_else(condition == 'ex', 'full', condition)) %>%
        distinct()
    } else {
      message('  WARNING: s301fl common exemptions not found: ', cpath)
    }
  }

  kpath <- fl_cfg$country_exemptions
  if (!is.null(kpath)) {
    kpath <- if (file.exists(kpath)) kpath else here(kpath)
    if (file.exists(kpath)) {
      out$country <- read_csv(kpath, col_types = cols(.default = col_character())) %>%
        mutate(country = strsplit(countries, ';')) %>%
        tidyr::unnest(country) %>%
        transmute(country = trimws(country), hts8 = hts_code,
                  condition = if_else(condition == 'ex', 'full', condition)) %>%
        distinct()
    } else {
      message('  WARNING: s301fl country exemptions not found: ', kpath)
    }
  }

  out
}


#' Does a revision's validity interval reach a policy activation date?
#'
#' A duty whose effective date falls strictly INSIDE a revision interval (§301
#' Brazil: 2026-07-22 vs rev_12 published 2026-07-21) or after the last published
#' revision (§338 Canada: 2026-08-19) must still be COMPUTED for the enclosing
#' revision, so the activation gate can then expose it only from its effective
#' date onward. Computing it only when `revision effective_date >= activation`
#' would delay the duty to the next revision — days or weeks late.
#'
#' @param revision_id This revision's id
#' @param effective_date This revision's effective date
#' @param activation_date The policy's legal effective date
#' @param rev_dates Optional pre-loaded revision_dates (avoids a reload)
#' @return TRUE if this revision's interval covers activation_date
revision_interval_covers <- function(revision_id, effective_date, activation_date,
                                     rev_dates = NULL) {
  eff <- as.Date(effective_date)
  act <- as.Date(activation_date)
  if (is.na(eff) || is.na(act)) return(FALSE)
  if (eff >= act) return(TRUE)          # revision starts on/after the activation

  rd <- rev_dates
  if (is.null(rd)) {
    rd <- tryCatch(suppressMessages(load_revision_dates()), error = function(e) NULL)
  }
  if (is.null(rd) || !all(c('revision', 'effective_date') %in% names(rd))) return(FALSE)

  rd <- rd %>% arrange(effective_date)
  i <- match(revision_id, rd$revision)
  if (is.na(i)) return(FALSE)
  # Interval runs to the day before the next revision; the last one runs open-ended.
  end <- if (i < nrow(rd)) as.Date(rd$effective_date[i + 1]) - 1 else as.Date('9999-12-31')
  act <= end
}


#' Per-row mask: is this product-country subject to Section 232?
#'
#' Several 2026 authorities carve out §232-covered articles ENTIRELY rather than
#' splitting by metal content:
#'   - §301 Brazil, note 50(a)(vi) / heading 9903.05.07
#'   - §338 Canada, Proclamation 11047 para. 2 ("shall not apply to articles
#'     subject to duties pursuant to section 232")
#' Both need the same test, so it lives here once.
#'
#' A product is in §232 scope if it carries a statutory §232 rate, or sits in an
#' IN-SCOPE annex tier. Annex II is deliberately excluded: the April 2026
#' proclamation REMOVED those products from §232 entirely, so they are not
#' "subject to" §232 and the carve-out must not shield them. Heading programs
#' (autos, copper, wood, MHD, semiconductors) are covered by the statutory-rate
#' clause whenever their program is active.
#'
#' @param rates Rates tibble (needs statutory_rate_232 and/or s232_annex)
#' @return Logical vector, length nrow(rates)
s232_scope_mask <- function(rates) {
  n <- nrow(rates)
  if (n == 0) return(logical(0))
  mask <- rep(FALSE, n)
  if ('statutory_rate_232' %in% names(rates)) {
    mask <- mask | coalesce(rates$statutory_rate_232 > 0, FALSE)
  }
  if ('rate_232' %in% names(rates)) {
    mask <- mask | coalesce(rates$rate_232 > 0, FALSE)
  }
  if ('s232_annex' %in% names(rates)) {
    mask <- mask | coalesce(rates$s232_annex %in%
                              c('annex_1a', 'annex_1b', 'annex_1c', 'annex_3'), FALSE)
  }
  mask
}


#' Compute per-product-country Section 301 Brazil rates
#'
#' USTR Notice of Action, FR Doc 2026-14542 (91 FR 45516), published 2026-07-20,
#' duties effective 2026-07-22: 25% additional ad valorem on ALL products of
#' Brazil via heading 9903.05.01 / U.S. note 50, except the note-50(a)(ii)-(v)
#' product lists. Rate is sourced from the HTS heading where available and falls
#' back to the configured literal.
#'
#' Exclusions:
#'   - note 50(a)(ii)+(iii): unconditional, fully exempt (875 hts8)
#'   - note 50(a)(iv)/(v): USE-conditional civil-aircraft (546) / pharmaceutical
#'     (705) lists, share-scaled (PLACEHOLDER shares — docs/assumptions.md)
#'   - note 50(a)(vi) / heading 9903.05.07: articles subject to §232 are excluded
#'     ENTIRELY (a full per-article exclusion, not a content split)
#'
#' NOT modeled: the one-week in-transit window (9903.05.02), donations and
#' informational materials (9903.05.08-.09).
#'
#' @param rates Rates tibble for this revision (needs hts10, country, and the
#'   §232 columns for the note-50(a)(vi) mask)
#' @param br_cfg policy_params$SECTION_301_BRAZIL
#' @param effective_date Revision effective date
#' @param hts_rate Optional rate parsed from heading 9903.05.01 (overrides config)
#' @return Numeric vector, length nrow(rates), of Brazil §301 rates
compute_s301br_rates <- function(rates, br_cfg, effective_date, hts_rate = NULL) {
  n <- nrow(rates)
  if (n == 0 || is.null(br_cfg)) return(rep(0, n))

  eff <- as.Date(effective_date)
  cty <- as.character(br_cfg$country %||% '3510')
  rate <- if (!is.null(hts_rate) && !is.na(hts_rate) && hts_rate > 0) {
    hts_rate
  } else {
    as.numeric(br_cfg$rate %||% 0)
  }
  if (rate <= 0) return(rep(0, n))

  is_br <- rates$country == cty
  if (!any(is_br)) return(rep(0, n))

  hts8 <- substr(rates$hts10, 1, 8)
  read_hts8 <- function(p) {
    if (is.null(p)) return(character(0))
    p <- if (file.exists(p)) p else here(p)
    if (!file.exists(p)) return(character(0))
    t <- suppressWarnings(read_csv(p, col_types = cols(.default = col_character())))
    col <- intersect(c('hts8', 'hts_code', 'hts_prefix'), names(t))[1]
    if (is.na(col)) character(0) else unique(substr(t[[col]], 1, 8))
  }

  flat  <- read_hts8(br_cfg$exempt_products)
  air   <- read_hts8(br_cfg$aircraft_products)
  pharm <- read_hts8(br_cfg$pharma_products)
  air_share   <- as.numeric(br_cfg$aircraft_exempt_share %||% 0)
  pharm_share <- as.numeric(br_cfg$pharma_exempt_share %||% 0)

  exempt_share <- rep(0, n)
  exempt_share <- pmax(exempt_share, if_else(hts8 %in% air,   air_share,   0))
  exempt_share <- pmax(exempt_share, if_else(hts8 %in% pharm, pharm_share, 0))
  exempt_share <- pmax(exempt_share, if_else(hts8 %in% flat,  1,           0))

  # note 50(a)(vi): full exclusion for articles subject to §232.
  exempt_share <- pmax(exempt_share, if_else(s232_scope_mask(rates), 1, 0))

  out <- rate * (1 - pmin(1, exempt_share))
  out[!is_br] <- 0
  # Pre-effective-date revisions get 0; the activation gate additionally zeroes
  # sub-intervals inside the enclosing revision (see collect_activation_adjustments).
  if (!is.null(br_cfg$effective_date) && eff < as.Date(br_cfg$effective_date)) {
    out[] <- 0
  }
  out
}


#' Compute per-product-country Section 301 forced-labor rates
#'
#' USTR Notice of Action 91 FR 47318 + presidential document 91 FR 47717,
#' effective 2026-07-24: additional duties on ALL products of 60 investigated
#' economies, with the Annex I/II exclusions of U.S. note 52(b)-(k).
#'
#' Rate resolution, in order:
#'   1. Tier lookup. FLAT tiers add fl_rate outright. CAP tiers ("10% total-duty
#'      cap") instead add max(0, cap - base), the annex_3 floor shape — treating a
#'      cap as additive would overcharge every capped economy by its whole MFN
#'      rate.
#'   2. Exempt share. Unconditional exclusions (Annex I 'full'/'ex', Annex II
#'      'full') are share 1.0. USE-conditional exclusions cannot be observed on an
#'      hts8-grained model, so they are approximated by a share of imports:
#'      civil-aircraft use and pharmaceutical applications from config
#'      (PLACEHOLDERS — see docs/assumptions.md), and the CAFTA-DR preference
#'      condition ('fta') proxied by the measured HS2xcountry MFN-exemption share,
#'      which is this repo's existing estimate of preference-claim rates.
#'      Where several conditions cover one line the most generous (max) wins.
#'   3. rate = applicable * (1 - exempt_share).
#'
#' Cap base: economies listed in post_preference_cap_countries have the cap
#' measured against the post-preference (effective) base; the rest against the
#' statutory MFN base. Falls back to base_rate when statutory is unavailable.
#'
#' NOT modeled: the in-transit window (heading 9903.05.85).
#'
#' Additional carve-outs evaluated per product-COUNTRY (not per hts8), which is
#' why this operates on the rates frame rather than the product list:
#'   - note 52(f) / heading 9903.05.90: articles subject to §232 are excluded
#'     ENTIRELY (aluminum/steel/copper + derivatives, autos + parts, wood, MHD +
#'     parts, semiconductors). A scope mask, not a content split.
#'   - note 52(g)/(h) / headings 9903.05.93-.94: products of Canada / Mexico
#'     entered FREE of duty under USMCA are exempt from 9903.05.29 / 9903.05.55.
#'     Share-scaled by the measured USMCA utilization share when available,
#'     falling back to binary eligibility.
#'
#' @param rates Rates frame for this revision. Needs hts10, country, base_rate;
#'   uses statutory_base_rate, statutory_rate_232/rate_232/s232_annex (note 52(f)),
#'   and usmca_share/usmca_eligible (note 52(g)/(h)) when present.
#' @param fl_cfg policy_params$SECTION_301_FORCED_LABOR
#' @param effective_date Revision effective date (gates the patented-pharma annex)
#' @param mfn_shares Optional tibble(hs2, cty_code, exemption_share) for the
#'   'fta' preference-claim proxy; NULL treats fta lines as fully exempt
#' @return Numeric vector, length nrow(rates)
compute_s301fl_rates <- function(rates, fl_cfg, effective_date, mfn_shares = NULL) {
  n <- nrow(rates)
  if (n == 0 || is.null(fl_cfg)) return(rep(0, n))

  eff <- as.Date(effective_date)
  if (!is.null(fl_cfg$effective_date) && eff < as.Date(fl_cfg$effective_date)) {
    return(rep(0, n))   # regime not yet in force for this revision
  }

  tiers <- s301fl_country_tiers(unique(rates$country), fl_cfg)
  if (nrow(tiers) == 0) return(rep(0, n))

  ex <- load_s301fl_exemptions(fl_cfg)
  air_share <- as.numeric(fl_cfg$aircraft_exempt_share %||% 0)
  pharma_share <- as.numeric(fl_cfg$pharma_exempt_share %||% 0)
  post_pref <- as.character(fl_cfg$post_preference_cap_countries %||% character(0))

  # Annex I Part B adds patented pharmaceuticals from a later date.
  pat_hts8 <- character(0)
  pat_date <- fl_cfg$patented_pharma_exempt_date
  if (!is.null(pat_date) && eff >= as.Date(pat_date)) {
    ppath <- fl_cfg$patented_pharma_products
    if (!is.null(ppath)) {
      ppath <- if (file.exists(ppath)) ppath else here(ppath)
      if (file.exists(ppath)) {
        pp_tbl <- suppressWarnings(read_csv(ppath, col_types = cols(.default = col_character())))
        col <- intersect(c('hts8', 'hts_prefix', 'hts_code'), names(pp_tbl))[1]
        if (!is.na(col)) pat_hts8 <- unique(substr(pp_tbl[[col]], 1, 8))
      }
    }
  }

  base_col <- if ('statutory_base_rate' %in% names(rates)) 'statutory_base_rate' else 'base_rate'
  out <- rates %>%
    mutate(.row = row_number(),
           hts8 = substr(hts10, 1, 8),
           hs2 = substr(hts10, 1, 2),
           base_eff = coalesce(base_rate, 0),
           base_stat = coalesce(.data[[base_col]], base_rate, 0)) %>%
    select(.row, hts10, country, hts8, hs2, base_eff, base_stat) %>%
    inner_join(tiers, by = 'country')
  if (nrow(out) == 0) return(rep(0, n))

  # Unconditional / conditional exemption shares, keyed by hts8.
  common_share <- ex$common %>%
    mutate(share = case_when(condition == 'full'     ~ 1,
                             condition == 'aircraft' ~ air_share,
                             condition == 'pharma'   ~ pharma_share,
                             TRUE ~ 0)) %>%
    group_by(hts8) %>% summarise(common_share = max(share), .groups = 'drop')

  country_full <- ex$country %>% filter(condition == 'full') %>%
    distinct(country, hts8) %>% mutate(country_share = 1)
  country_fta <- ex$country %>% filter(condition == 'fta') %>% distinct(country, hts8)

  out <- out %>%
    left_join(common_share, by = 'hts8') %>%
    left_join(country_full, by = c('country', 'hts8')) %>%
    mutate(fta_hit = FALSE)

  if (nrow(country_fta) > 0) {
    out <- out %>%
      left_join(country_fta %>% mutate(.fta = TRUE), by = c('country', 'hts8')) %>%
      mutate(fta_hit = coalesce(.fta, FALSE)) %>% select(-.fta)
  }

  # note 52(f) / heading 9903.05.90: full §232 exclusion (shared mask).
  s232_by_row <- s232_scope_mask(rates)
  # note 52(g)/(h) / headings 9903.05.93-.94: Canada / Mexico goods entered FREE
  # under USMCA. Prefer the measured utilization share; fall back to binary
  # eligibility; contribute nothing when neither column is present.
  usmca_share_by_row <- rep(0, n)
  usmca_ctys <- c('1220', '2010')                        # Canada, Mexico
  in_usmca_cty <- rates$country %in% usmca_ctys
  if ('usmca_share' %in% names(rates)) {
    usmca_share_by_row <- if_else(in_usmca_cty,
                                  pmin(1, pmax(0, coalesce(rates$usmca_share, 0))), 0)
  } else if ('usmca_eligible' %in% names(rates)) {
    usmca_share_by_row <- if_else(in_usmca_cty & coalesce(rates$usmca_eligible, FALSE), 1, 0)
  }

  out <- out %>%
    mutate(s232_share = if_else(s232_by_row[.row], 1, 0),
           usmca_ex_share = usmca_share_by_row[.row])

  # 'fta' lines are exempt only when the good is actually entered under the
  # preference. Proxy the claim rate with the measured HS2xcountry MFN-exemption
  # share; with no share data, treat the exclusion as full (the legal default).
  if (!is.null(mfn_shares) && nrow(mfn_shares) > 0) {
    out <- out %>%
      left_join(mfn_shares %>% select(hs2, cty_code, exemption_share),
                by = c('hs2', 'country' = 'cty_code')) %>%
      mutate(fta_share = if_else(fta_hit, coalesce(exemption_share, 0), 0)) %>%
      select(-exemption_share)
  } else {
    out <- out %>% mutate(fta_share = if_else(fta_hit, 1, 0))
  }

  scored <- out %>%
    mutate(
      pat_share = if_else(hts8 %in% pat_hts8, 1, 0),
      exempt_share = pmin(1, pmax(coalesce(common_share, 0),
                                  coalesce(country_share, 0),
                                  fta_share, pat_share,
                                  s232_share, usmca_ex_share)),
      cap_base = if_else(country %in% post_pref, base_eff, base_stat),
      applicable = if_else(fl_is_cap, pmax(0, fl_rate - cap_base), fl_rate),
      value = applicable * (1 - exempt_share)
    )

  res <- rep(0, n)
  res[scored$.row] <- scored$value
  res
}


#' Per-country Section 232 DERIVATIVE rate, honoring country rate overrides
#'
#' Port of upstream cf2d5951 #1. Rev_14 (2025-06-04) carries explicit UK
#' *derivative* entries at 25% (9903.81.96-.99 steel, 9903.85.13-.14 aluminum)
#' which `extract_section232_rates()` parses into
#' `s232_rates$steel_country_overrides` / `aluminum_country_overrides`. Those
#' overrides were previously applied only to the PRIMARY metal programs, so UK
#' outside-chapter derivatives were charged the blanket 50%
#' (metal-content-scaled) instead of 25% for 2025-06-04 -> 2026-04-05. The
#' annex era (2026-04-06+) is unaffected: it has its own UK handling and the
#' derivative gates are off.
#'
#' Precedence: exemption zeros win over an override (an exempt country pays
#' nothing regardless of a parsed override rate).
#'
#' @param country_vec Character vector of country codes
#' @param exempt_list Exemption spec passed to is_232_exempt()
#' @param blanket_rate Default derivative rate for non-exempt countries
#' @param overrides Named list of country_code -> rate (may be NULL/empty)
#' @return Numeric vector of per-country derivative rates
derivative_country_rates <- function(country_vec, exempt_list, blanket_rate,
                                     overrides = NULL) {
  exempt <- map_lgl(country_vec, ~is_232_exempt(.x, exempt_list))
  rate <- if_else(exempt, 0, blanket_rate)
  if (length(overrides %||% list()) > 0) {
    ov_idx <- match(country_vec, names(overrides))
    has_ov <- !is.na(ov_idx) & !exempt
    if (any(has_ov)) {
      rate[has_ov] <- unlist(overrides, use.names = FALSE)[ov_idx[has_ov]]
    }
  }
  rate
}


#' Map matched HTS10 products to their per-product Ch. 99 derivative code
#'
#' The derivative CSV carries the legally correct heading per product
#' (US Note 16/19 subdivision membership: e.g. 9903.85.04 = Note 19(i),
#' 9903.85.07 = 19(j), 9903.85.08 = 19(k)). Longest prefix wins. If one
#' HTS10 matches equal-length prefixes mapped to different same-metal
#' headings, the more specific subdivision (the heading covering the
#' fewest CSV products) wins and a warning is emitted — subdivision lists
#' are meant to be disjoint, so a real conflict is a CSV defect.
#'
#' @param matched_hts10 Character vector of HTS10 codes matched to this type
#' @param type_products Derivative CSV rows filtered to one derivative_type
#' @param type_label 'aluminum' or 'steel' (becomes deriv_type join key)
#' @return Tibble with hts10, deriv_type, deriv_ch99_code
build_deriv_ch99_map <- function(matched_hts10, type_products, type_label) {
  empty <- tibble(hts10 = character(0), deriv_type = character(0),
                  deriv_ch99_code = character(0))
  if (length(matched_hts10) == 0 || is.null(type_products) ||
      nrow(type_products) == 0 || !'ch99_code' %in% names(type_products)) {
    return(empty)
  }

  heading_sizes <- type_products %>%
    filter(!is.na(ch99_code)) %>%
    count(ch99_code, name = 'n_products')
  prefixes <- type_products %>%
    filter(!is.na(ch99_code)) %>%
    distinct(hts_prefix, ch99_code) %>%
    left_join(heading_sizes, by = 'ch99_code')
  if (nrow(prefixes) == 0) return(empty)

  hits <- tidyr::crossing(tibble(hts10 = unique(matched_hts10)), prefixes) %>%
    filter(startsWith(hts10, hts_prefix))
  if (nrow(hits) == 0) return(empty)

  resolved <- hits %>%
    group_by(hts10) %>%
    filter(nchar(hts_prefix) == max(nchar(hts_prefix))) %>%
    arrange(n_products, ch99_code, .by_group = TRUE) %>%
    summarise(deriv_ch99_code = first(ch99_code),
              n_codes = n_distinct(ch99_code), .groups = 'drop')

  n_conflict <- sum(resolved$n_codes > 1)
  if (n_conflict > 0) {
    warning(n_conflict, ' ', type_label, ' derivative HTS10(s) match prefixes ',
            'mapped to multiple ch99 headings; resolved to the most specific ',
            'subdivision. Review s232_derivative_products.csv.')
  }

  resolved %>%
    transmute(hts10, deriv_type = type_label, deriv_ch99_code)
}


#' Load floor country product exemptions
#'
#' Products exempt from the 15% tariff floor for EU, Japan, S. Korea,
#' Switzerland/Liechtenstein. Categories: PTAAP (agricultural/natural
#' resources), civil aircraft, non-patented pharmaceuticals. Parsed from
#' US Notes to Chapter 99 by scrape_us_notes.R --floor-exemptions.
#'
#' @param path Path to floor_exempt_products.csv
#' @return Tibble with hts8, category, country_group, ch99_code; or empty tibble if missing
load_floor_exempt_products <- function(path = here('resources', 'floor_exempt_products.csv')) {
  if (!file.exists(path)) {
    message('  Floor exempt products file not found: ', path)
    return(tibble(hts8 = character(), category = character(),
                  country_group = character(), ch99_code = character()))
  }

  products <- read_csv(path, col_types = cols(.default = col_character()))
  message('  Loaded ', nrow(products), ' floor exempt products (',
          n_distinct(products$hts8), ' unique HTS8)')
  return(products)
}


#' Load revision-specific floor country product exemptions
#'
#' Tries per-revision file first (data/us_notes/floor_exempt_{revision}.csv),
#' then falls back to the static resources/floor_exempt_products.csv.
#'
#' @param revision_id Character revision ID (e.g., 'rev_18', '2026_basic')
#' @return Tibble with hts8, category, country_group, ch99_code; or empty tibble
load_revision_floor_exemptions <- function(revision_id) {
  # Try per-revision file first
  revision_path <- here('data', 'us_notes', paste0('floor_exempt_', revision_id, '.csv'))
  if (file.exists(revision_path)) {
    products <- read_csv(revision_path, col_types = cols(.default = col_character()))
    message('  Loaded ', nrow(products), ' floor exempt products for ', revision_id,
            ' (', n_distinct(products$hts8), ' unique HTS8)')
    return(products)
  }

  # Fall back to static file
  message('  No per-revision floor exemptions for ', revision_id,
          '; using static fallback')
  return(load_floor_exempt_products())
}


#' Load product-level USMCA utilization shares from USITC DataWeb SPI data
#'
#' Per-HTS10 x country USMCA shares from DataWeb SPI programs S/S+.
#' Generated by src/download_usmca_dataweb.R.
#' Returns NULL if file not found (triggers fallback to binary eligibility).
#'
#' Modes (from policy_params$USMCA_SHARES$mode):
#'   'h2_average' (default): averages months 7-12 of the configured year. Reflects post-tariff
#'      steady-state USMCA utilization (CA ~85-88%, MX ~85-88%) without monthly noise.
#'   'annual': loads resources/usmca_product_shares_{year}.csv
#'   'monthly': loads resources/usmca_product_shares_{year}_{MM}.csv based on effective_date
#'   'fixed_month': loads resources/usmca_product_shares_{year}_{MM}.csv using configured month
#'   'hybrid_rolling': Q1 average for Jan-Mar, 3-month rolling average (m, m-1, m-2) from April.
#'      Smooths the mid-2025 USMCA utilization jump while capturing the behavioral shift.
#'      Rolling uses available months only; falls back to annual if no monthly files found.
#'
#' @param policy_params Policy params list (uses usmca_shares mode/year)
#' @param path Override path (ignores mode/year selection if provided)
#' @param effective_date Date string (YYYY-MM-DD) for monthly mode file selection
#' @return Tibble with hts10, cty_code, usmca_share; or NULL if missing
load_usmca_product_shares <- function(policy_params = NULL, path = NULL, effective_date = NULL) {
  if (is.null(path)) {
    mode <- policy_params$USMCA_SHARES$mode %||% 'annual'
    year <- policy_params$USMCA_SHARES$year %||% NULL

    if (mode == 'h2_average') {
      # Average months 7-12: post-tariff steady-state USMCA utilization
      year <- year %||% 2025L
      monthly_shares <- list()
      for (m in 7L:12L) {
        m_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', year, m))
        if (file.exists(m_path)) {
          monthly_shares[[length(monthly_shares) + 1L]] <- read_csv(
            m_path, col_types = cols(.default = col_guess(),
                                     hts10 = col_character(), cty_code = col_character(),
                                     usmca_share = col_double()), show_col_types = FALSE
          )
        }
      }
      if (length(monthly_shares) > 0) {
        combined <- bind_rows(monthly_shares)
        has_values <- all(c('total_value', 'usmca_value') %in% names(combined))
        if (has_values) {
          # Value-weighted aggregation: sum(usmca_value) / sum(total_value).
          # Zero-trade pairs get NA (not 0): a code with no H2 trade carries
          # no claim signal — e.g. statistical splits introduced after 2025
          # (2709.00.20.10) defaulted to share 0 -> full CA/MX rate (upstream
          # extreme-eta review item 6). The application step in
          # 06_calculate_rates.R falls back to the HS8-level share (attached
          # below as attr 'hs8_shares') before defaulting to 0.
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(
              total_value = sum(total_value, na.rm = TRUE),
              usmca_value = sum(usmca_value, na.rm = TRUE),
              .groups = 'drop'
            ) %>%
            mutate(
              usmca_share = if_else(total_value > 0,
                                    usmca_value / total_value,
                                    NA_real_)
            )
          hs8_shares <- combined %>%
            group_by(hts8 = substr(hts10, 1, 8), cty_code) %>%
            summarise(
              usmca_share_hs8 = if_else(sum(total_value) > 0,
                                        sum(usmca_value) / sum(total_value),
                                        NA_real_),
              .groups = 'drop'
            ) %>%
            filter(!is.na(usmca_share_hs8))
          combined <- combined %>% select(hts10, cty_code, usmca_share)
          attr(combined, 'hs8_shares') <- hs8_shares
          message('  Loaded USMCA H2 average (value-weighted): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months, Jul-Dec ', year,
                  '); HS8 fallback table: ', nrow(hs8_shares), ' pairs')
        } else {
          # Fallback: simple average of ratios (legacy monthly CSVs without value columns)
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(usmca_share = mean(usmca_share, na.rm = TRUE), .groups = 'drop')
          message('  Loaded USMCA H2 average (ratio-averaged, no value cols): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months, Jul-Dec ', year, ')')
        }
        return(combined)
      } else {
        message('  No H2 monthly USMCA files found for ', year, ' — falling back to annual')
        path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
      }

    } else if (mode == 'fixed_month') {
      fixed_month <- policy_params$USMCA_SHARES$month %||% 12L
      year <- year %||% 2025L
      monthly_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', year, as.integer(fixed_month)))
      if (file.exists(monthly_path)) {
        path <- monthly_path
      } else {
        message('  Fixed-month USMCA file not found for ', year, '-', sprintf('%02d', fixed_month),
                ' — falling back to annual')
        path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
      }
    } else if (mode == 'hybrid_rolling' && !is.null(effective_date)) {
      # Q1 average for Jan-Mar; 3-month rolling (m, m-1, m-2) from April onward
      eff <- as.Date(effective_date)
      year <- year %||% as.integer(format(eff, '%Y'))
      month_num <- as.integer(format(eff, '%m'))
      if (eff < as.Date(paste0(year, '-01-01'))) month_num <- 1L
      if (eff > as.Date(paste0(year, '-12-31'))) month_num <- 12L

      if (month_num <= 3L) {
        # Q1: average all available months 1-3
        window <- 1L:3L
      } else {
        # Rolling: months m, m-1, m-2
        window <- (month_num - 2L):month_num
      }

      # Load available monthly files in the window
      monthly_shares <- list()
      for (m in window) {
        m_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', year, m))
        if (file.exists(m_path)) {
          monthly_shares[[length(monthly_shares) + 1L]] <- read_csv(
            m_path, col_types = cols(hts10 = col_character(), cty_code = col_character(),
                                     usmca_share = col_double()), show_col_types = FALSE
          )
        }
      }

      if (length(monthly_shares) > 0) {
        combined <- bind_rows(monthly_shares)
        has_values <- all(c('total_value', 'usmca_value') %in% names(combined))
        window_label <- paste0(sprintf('%02d', window[1]), '-', sprintf('%02d', window[length(window)]))
        if (has_values) {
          # Same zero-trade -> NA + HS8 fallback semantics as the h2_average
          # branch above (see comment there).
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(
              total_value = sum(total_value, na.rm = TRUE),
              usmca_value = sum(usmca_value, na.rm = TRUE),
              .groups = 'drop'
            ) %>%
            mutate(
              usmca_share = if_else(total_value > 0,
                                    usmca_value / total_value,
                                    NA_real_)
            )
          hs8_shares <- combined %>%
            group_by(hts8 = substr(hts10, 1, 8), cty_code) %>%
            summarise(
              usmca_share_hs8 = if_else(sum(total_value) > 0,
                                        sum(usmca_value) / sum(total_value),
                                        NA_real_),
              .groups = 'drop'
            ) %>%
            filter(!is.na(usmca_share_hs8))
          combined <- combined %>% select(hts10, cty_code, usmca_share)
          attr(combined, 'hs8_shares') <- hs8_shares
          message('  Loaded USMCA hybrid rolling (value-weighted): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months in window ',
                  window_label, '); HS8 fallback table: ', nrow(hs8_shares), ' pairs')
        } else {
          combined <- combined %>%
            group_by(hts10, cty_code) %>%
            summarise(usmca_share = mean(usmca_share, na.rm = TRUE), .groups = 'drop')
          message('  Loaded USMCA hybrid rolling (ratio-averaged): ', nrow(combined),
                  ' product-country pairs (', length(monthly_shares), ' months in window ',
                  window_label, ')')
        }
        return(combined)
      } else {
        message('  No monthly USMCA files found for hybrid rolling — falling back to annual')
        path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
      }

    } else if (mode == 'monthly' && !is.null(effective_date)) {
      eff <- as.Date(effective_date)
      year <- year %||% as.integer(format(eff, '%Y'))
      # Clamp to year boundaries
      month_num <- as.integer(format(eff, '%m'))
      if (eff < as.Date(paste0(year, '-01-01'))) month_num <- 1L
      if (eff > as.Date(paste0(year, '-12-31'))) month_num <- 12L
      monthly_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', year, month_num))
      if (file.exists(monthly_path)) {
        path <- monthly_path
      } else {
        # Try to find the latest available monthly file before this month
        found_fallback <- FALSE
        for (m in (month_num - 1L):1L) {
          fallback_path <- here('resources', sprintf('usmca_product_shares_%d_%02d.csv', year, m))
          if (file.exists(fallback_path)) {
            message('  Monthly USMCA file not found for ', year, '-', sprintf('%02d', month_num),
                    ' — using latest available: month ', sprintf('%02d', m))
            path <- fallback_path
            found_fallback <- TRUE
            break
          }
        }
        if (!found_fallback) {
          message('  No monthly USMCA files found for ', year, ' — falling back to annual')
          path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
        }
      }
    } else {
      if (!is.null(year)) {
        path <- here('resources', paste0('usmca_product_shares_', year, '.csv'))
      } else {
        path <- here('resources', 'usmca_product_shares.csv')
      }
    }
  }
  if (!file.exists(path)) {
    message('  USMCA product shares file not found — using binary eligibility')
    return(NULL)
  }
  shares <- read_csv(path, col_types = cols(
    hts10 = col_character(),
    cty_code = col_character(),
    usmca_share = col_double()
  ))
  message('  Loaded USMCA product shares: ', nrow(shares),
          ' product-country pairs from ', basename(path))
  return(shares)
}


#' Load MFN exemption shares (FTA/GSP preference utilization)
#'
#' HS2 x country exemption shares computed from Census calculated duty data.
#' effective_mfn = mfn_rate * (1 - exemption_share).
#' Sourced from Tariff-ETRs project. Returns NULL if file not found.
#'
#' @param path Path to mfn_exemption_shares.csv
#' @return Tibble with hs2, cty_code, exemption_share; or NULL if missing
load_mfn_exemption_shares <- function(path = here('resources', 'mfn_exemption_shares.csv')) {
  if (!file.exists(path)) {
    message('  MFN exemption shares file not found — using statutory base rates')
    return(NULL)
  }
  shares <- read_csv(path, col_types = cols(
    hs2 = col_character(),
    cty_code = col_character(),
    exemption_share = col_double()
  ))
  # Clamp exemption shares to [0, 1]
  shares <- shares %>%
    mutate(exemption_share = pmin(pmax(exemption_share, 0), 1))
  message('  Loaded MFN exemption shares: ', nrow(shares), ' HS2-country pairs')
  return(shares)
}


#' Load fentanyl carve-out product lists
#'
#' Product-specific fentanyl rate carve-outs: energy/critical minerals (CA) and
#' potash (CA/MX) receive a lower fentanyl rate than the general blanket.
#' Product lists sourced from Tariff-ETRs config (US Note 2 subdivisions).
#'
#' @param path Path to fentanyl_carveout_products.csv
#' @return Tibble with hts8, ch99_code, category columns (or NULL if file missing)
load_fentanyl_carveouts <- function(path = here('resources', 'fentanyl_carveout_products.csv')) {
  if (!file.exists(path)) {
    message('  Fentanyl carve-out products file not found: ', path)
    return(NULL)
  }

  carveouts <- read_csv(path, col_types = cols(
    hts8 = col_character(),
    ch99_code = col_character(),
    category = col_character()
  ))

  message('  Loaded ', nrow(carveouts), ' fentanyl carve-out product prefixes (',
          n_distinct(carveouts$category), ' categories)')
  return(carveouts)
}


#' Load metal content shares for Section 232 derivative products
#'
#' For derivative 232 products, the tariff applies only to the metal content
#' portion of customs value. This function returns per-product metal shares.
#'
#' Three methods:
#'   flat: All derivative products get metal_share = flat_share (default 0.50)
#'   cbo:  Product-level buckets from resources/cbo/ files
#' Load Section 232 annex product classification
#'
#' Reads the annex product mapping from the static resource file. Returns a
#' tibble with hts_prefix and s232_annex columns for prefix-matching in
#' 06_calculate_rates.R. When the resource file is empty (header only), returns
#' an empty tibble — the annex rate override step becomes a no-op.
#'
#' @param effective_date Date to filter entries by effective_date column
#' @param resource_path Path to s232_annex_products.csv
#' @return Tibble with columns: hts_prefix, s232_annex, s232_metal
#'   (s232_metal = the covered metal — steel/aluminum/copper — from the annex
#'   list's metal_type; NA when the resource predates the metal_type column).
load_annex_products <- function(effective_date = NULL,
                                resource_path = here('resources', 's232_annex_products.csv')) {
  empty <- tibble(hts_prefix = character(), s232_annex = character(),
                  s232_metal = character())
  if (!file.exists(resource_path)) {
    return(empty)
  }

  annex_map <- read_csv(resource_path, col_types = cols(.default = col_character()))

  if (nrow(annex_map) == 0) {
    message('  Annex products: resource file empty (pending HTS JSON)')
    return(empty)
  }

  # Filter by effective_date if column is present
  if ('effective_date' %in% names(annex_map) && !is.null(effective_date)) {
    annex_map <- annex_map %>%
      filter(is.na(effective_date) | effective_date <= as.character(!!effective_date))
  }

  # Carry metal_type through as s232_metal so the provenance layer can name the
  # covered metal (the coverage SOURCE), independent of the 9903.82 reporting
  # code, which is ambiguous in the annex era. Tolerate older resource files
  # that predate the column.
  if (!'metal_type' %in% names(annex_map)) annex_map$metal_type <- NA_character_
  annex_map %>%
    select(hts_prefix, s232_annex = annex, s232_metal = metal_type) %>%
    mutate(s232_annex = paste0('annex_', s232_annex)) %>%
    distinct(hts_prefix, .keep_all = TRUE)
}


#'         (high=0.75, low=0.25, copper=0.90)
#'   bea:  HS10-level shares from BEA 2017 Detail I-O table
#'         (resources/metal_content_shares_bea_hs10.csv)
#'
#' Products in primary_chapters (72, 73, 76) always get metal_share = 1.0.
#' Non-derivative products outside primary chapters get metal_share = 1.0
#' (no metal adjustment — they don't have 232 rates).
#'
#' @param metal_cfg Metal content config list from policy_params.yaml
#' @param hts10_codes Character vector of HTS10 codes to compute shares for
#' @param derivative_hts10 Character vector of HTS10 codes identified as 232
#'   derivatives. Only these products receive metal_share < 1.0.
#' @return Tibble with hts10 and metal_share columns
load_metal_content <- function(metal_cfg = NULL, hts10_codes = character(0),
                               derivative_hts10 = character(0)) {
  if (length(hts10_codes) == 0) {
    return(tibble(hts10 = character(), metal_share = numeric(),
                  steel_share = numeric(), aluminum_share = numeric(),
                  copper_share = numeric(), other_metal_share = numeric()))
  }

  method <- if (!is.null(metal_cfg)) metal_cfg$method %||% 'flat' else 'flat'
  flat_share <- if (!is.null(metal_cfg)) metal_cfg$flat_share %||% 0.50 else 0.50
  primary_chapters <- if (!is.null(metal_cfg)) unlist(metal_cfg$primary_chapters) else c('72', '73', '76')

  # Start with all products at metal_share = 1.0 (full metal / no adjustment)
  # and zero-filled per-type columns. The zero-filled schema keeps bind_rows()
  # stable across revisions and prevents NA propagation when flat/CBO methods
  # merge with BEA-era snapshots; downstream stacking decides whether these
  # per-type shares are informative enough to use via has_informative_per_type_shares().
  result <- tibble(
    hts10 = hts10_codes,
    metal_share = 1.0,
    steel_share = 0,
    aluminum_share = 0,
    copper_share = 0,
    other_metal_share = 0
  )

  # Flag derivative products — only these get metal_share < 1.0
  is_derivative <- result$hts10 %in% derivative_hts10

  if (sum(is_derivative) == 0) {
    message('  Metal content: no derivative products to adjust')
    return(result)
  }

  if (method == 'flat') {
    result$metal_share[is_derivative] <- flat_share
    message('  Metal content: flat method (', round(flat_share * 100),
            '% for ', sum(is_derivative), ' derivatives)')

  } else if (method == 'cbo') {
    cbo_high_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_high_share %||% 0.75 else 0.75
    cbo_low_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_low_share %||% 0.25 else 0.25
    cbo_copper_share <- if (!is.null(metal_cfg)) metal_cfg$cbo_copper_share %||% 0.90 else 0.90

    # Load CBO bucket files
    cbo_dir <- here('resources', 'cbo')
    high_path <- file.path(cbo_dir, 'alst_deriv_h.csv')
    low_path <- file.path(cbo_dir, 'alst_deriv_l.csv')
    copper_path <- file.path(cbo_dir, 'copper.csv')

    cbo_shares <- tibble(hts10 = character(), metal_share = numeric())

    if (file.exists(copper_path)) {
      copper <- read_csv(copper_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = copper$I_COMMODITY, metal_share = cbo_copper_share))
    }
    if (file.exists(high_path)) {
      high <- read_csv(high_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = high$I_COMMODITY, metal_share = cbo_high_share))
    }
    if (file.exists(low_path)) {
      low <- read_csv(low_path, col_types = cols(I_COMMODITY = col_character()))
      cbo_shares <- bind_rows(cbo_shares,
        tibble(hts10 = low$I_COMMODITY, metal_share = cbo_low_share))
    }

    # Priority: copper > high > low (first match kept)
    cbo_shares <- cbo_shares %>%
      distinct(hts10, .keep_all = TRUE)

    # Only apply CBO shares to derivative products
    result <- result %>%
      left_join(cbo_shares %>% rename(cbo_share = metal_share), by = 'hts10') %>%
      mutate(
        metal_share = case_when(
          !is_derivative ~ 1.0,               # non-derivatives stay at 1.0
          !is.na(cbo_share) ~ cbo_share,      # CBO match for derivatives
          TRUE ~ flat_share                    # fallback to flat for unmatched derivatives
        )
      ) %>%
      select(-cbo_share)

    n_cbo <- sum(!is.na(cbo_shares$hts10[cbo_shares$hts10 %in% derivative_hts10]))
    message('  Metal content: CBO method (', n_cbo, ' of ', sum(is_derivative),
            ' derivatives matched; high=', cbo_high_share, ', low=', cbo_low_share,
            ', copper=', cbo_copper_share, ')')

  } else if (method == 'bea') {
    # BEA I-O table shares at HS10 level (per-metal-type detail).
    # File generated by Tariff-ETRs build_metal_content_shares.R from 2017 BEA
    # Detail Use Table and HS10->NAICS->BEA crosswalk chain.
    bea_path <- here('resources', 'metal_content_shares_bea_hs10.csv')
    if (!file.exists(bea_path)) {
      stop('BEA metal content file not found: ', bea_path,
           '\nCopy from Tariff-ETRs or switch to flat/cbo method.')
    }

    bea_shares <- read_csv(bea_path, col_types = cols(
      hs10 = col_character(),
      .default = col_double()
    )) %>%
      select(hts10 = hs10,
             bea_steel = steel_share, bea_aluminum = aluminum_share,
             bea_copper = copper_share, bea_other = other_metal_share,
             bea_metal = metal_share)

    # metal_share gated on is_derivative (only derivatives get < 1.0).
    # Per-type shares populated for ALL BEA-matched products: copper heading
    # scaling needs copper_share on non-derivative ch74 products; stacking
    # guards on rate_232 > 0 so non-232 products are unaffected.
    result <- result %>%
      left_join(bea_shares, by = 'hts10') %>%
      mutate(
        metal_share = case_when(
          !is_derivative ~ 1.0,              # non-derivatives stay at 1.0
          !is.na(bea_metal) ~ bea_metal,     # BEA match for derivatives
          TRUE ~ flat_share                   # fallback to flat for unmatched derivatives
        ),
        steel_share       = pmin(if_else(!is.na(bea_steel), bea_steel, 0), 1.0),
        aluminum_share    = pmin(if_else(!is.na(bea_aluminum), bea_aluminum, 0), 1.0),
        copper_share      = pmin(if_else(!is.na(bea_copper), bea_copper, 0), 1.0),
        other_metal_share = pmin(if_else(!is.na(bea_other), bea_other, 0), 1.0)
      ) %>%
      select(-starts_with('bea_'))

    n_bea <- sum(bea_shares$hts10 %in% derivative_hts10)
    message('  Metal content: BEA method (', n_bea, ' of ', sum(is_derivative),
            ' derivatives matched; fallback=', flat_share, ')')

  } else {
    warning('Unknown metal_content method: ', method, '. Using flat fallback.')
    result$metal_share[is_derivative] <- flat_share
  }

  # Force primary chapters (72, 73, 76) to metal_share = 1.0 regardless of
  # derivative flag. These are base metal products — the tariff applies to
  # their full customs value, not a metal content fraction.
  is_primary <- substr(result$hts10, 1, 2) %in% primary_chapters
  if (any(is_primary)) {
    result$metal_share[is_primary] <- 1.0
    result$steel_share[is_primary] <- 0
    result$aluminum_share[is_primary] <- 0
    result$copper_share[is_primary] <- 0
    result$other_metal_share[is_primary] <- 0
  }

  return(result)
}


# =============================================================================
# Post-Interval Policy Adjustments
# =============================================================================

#' Collect date-bounded policy overrides that require post-interval adjustment
#'
#' Returns a list of adjustments with expiry dates and the zeroing action to apply.
#' Used by both point queries and interval-splitting aggregate paths.
#'
#' @param policy_params Policy params list from load_policy_params()
#' @return List of lists, each with `expiry_date`, `column`, and `label`
collect_expiry_adjustments <- function(policy_params) {
  adjustments <- list()

  # Section 122 expiry
  if (!is.null(policy_params$SECTION_122) &&
      !policy_params$SECTION_122$finalized) {
    adjustments <- c(adjustments, list(list(
      expiry_date = as.Date(policy_params$SECTION_122$expiry_date),
      column = 'rate_s122',
      label = 'Section 122'
    )))
  }

  # Swiss framework expiry (reverts floor override for CH/LI)
  if (!is.null(policy_params$SWISS_FRAMEWORK) &&
      !policy_params$SWISS_FRAMEWORK$finalized) {
    adjustments <- c(adjustments, list(list(
      expiry_date = as.Date(policy_params$SWISS_FRAMEWORK$expiry_date),
      column = 'rate_ieepa_recip',
      countries = policy_params$SWISS_FRAMEWORK$countries,
      label = 'Swiss framework'
    )))
  }

  return(adjustments)
}


#' Collect ACTIVATION (turn-on) adjustments from policy params
#'
#' The mirror image of collect_expiry_adjustments(). Some authorities take legal
#' effect on a date that falls STRICTLY INSIDE a revision interval, or after the
#' last published revision entirely — the HTS revision cadence and the Federal
#' Register effective dates are independent. Examples:
#'   - §301 Brazil       eff. 2026-07-22, but rev_12 is dated 2026-07-21
#'   - §338 Canada       eff. 2026-08-19, carried by NO published revision yet
#' Applying such a duty at the enclosing revision boundary would be days early;
#' waiting for the next revision would be days late.
#'
#' Rather than teach the daily layer to COMPUTE these regimes (which would
#' duplicate calculate_rates_for_revision()), the rate is computed normally in
#' 06_calculate_rates.R for the enclosing revision and this layer simply GATES
#' it: the column is zeroed for dates strictly BEFORE activation_date. That
#' makes activation structurally identical to expiry — same splitter, same
#' tested code path, opposite sign — instead of a second mechanism.
#'
#' Interval convention: an activation at date A contributes split point A - 1
#' (the last INACTIVE day), so the splitter opens a new sub-interval exactly at
#' A. This matches the expiry convention, where the split point is the last
#' ACTIVE day.
#'
#' @param policy_params Policy params list from load_policy_params()
#' @return List of adjustments, each with activation_date, column, optional
#'   countries, and label
collect_activation_adjustments <- function(policy_params) {
  adjustments <- list()
  if (is.null(policy_params)) return(adjustments)

  # Registry of config blocks that turn a rate column ON at a date. Each entry
  # is (policy_params key, rate column, label); the country scope is read from
  # the block's `country`/`countries` field when present (NULL = all countries).
  registry <- list(
    list(key = 'SECTION_301_BRAZIL',      column = 'rate_s301br', label = 'Section 301 Brazil'),
    list(key = 'SECTION_301_FORCED_LABOR', column = 'rate_s301fl', label = 'Section 301 forced labor'),
    list(key = 'SECTION_338',             column = 'rate_s338',   label = 'Section 338')
  )

  for (entry in registry) {
    cfg <- policy_params[[entry$key]]
    if (is.null(cfg) || is.null(cfg$effective_date)) next
    ctys <- cfg$countries %||% cfg$country
    adjustments <- c(adjustments, list(list(
      activation_date = as.Date(cfg$effective_date),
      column = entry$column,
      countries = if (is.null(ctys)) NULL else as.character(ctys),
      label = entry$label
    )))
  }

  return(adjustments)
}


#' Apply date-bounded policy expirations to a rate snapshot (point mode)
#'
#' Zeroes expired rate columns and recomputes totals via apply_stacking_rules().
#' For Swiss framework, zeroes the floor IEEPA rate for CH/LI only (conservative:
#' the pre-floor surcharge rate is not stored, so we revert to 0 rather than
#' guessing the original rate).
#'
#' @param snapshot Rate snapshot tibble
#' @param query_date Date for the point query
#' @param policy_params Policy params list from load_policy_params()
#' @return Adjusted snapshot with recomputed totals
apply_post_interval_adjustments_point <- function(snapshot, query_date, policy_params) {
  if (is.null(policy_params) || nrow(snapshot) == 0) return(snapshot)

  adjustments <- collect_expiry_adjustments(policy_params)
  needs_restacking <- FALSE

  for (adj in adjustments) {
    if (query_date > adj$expiry_date && adj$column %in% names(snapshot)) {
      if (!is.null(adj$countries)) {
        # Country-scoped adjustment (Swiss framework)
        snapshot <- snapshot %>%
          mutate(!!adj$column := if_else(country %in% adj$countries, 0, .data[[adj$column]]))
      } else {
        # Global adjustment (Section 122)
        snapshot[[adj$column]] <- 0
      }
      needs_restacking <- TRUE
    }
  }

  # Activation gating: zero a not-yet-effective duty for queries before its date.
  for (adj in collect_activation_adjustments(policy_params)) {
    if (query_date < adj$activation_date && adj$column %in% names(snapshot)) {
      if (!is.null(adj$countries)) {
        snapshot <- snapshot %>%
          mutate(!!adj$column := if_else(country %in% adj$countries, 0, .data[[adj$column]]))
      } else {
        snapshot[[adj$column]] <- 0
      }
      needs_restacking <- TRUE
    }
  }

  if (needs_restacking) {
    cty_china <- policy_params$CTY_CHINA %||% '5700'
    snapshot <- apply_stacking_rules(snapshot, cty_china = cty_china)
  }

  return(snapshot)
}


#' Get expiry split points within a revision interval
#'
#' Returns a sorted vector of dates at which policy adjustments take effect
#' within the given interval. Used by build_daily_aggregates() to split
#' revision intervals into sub-intervals with different policy states.
#'
#' @param valid_from Interval start date
#' @param valid_until Interval end date
#' @param policy_params Policy params list from load_policy_params()
#' @return Sorted Date vector of split points (each is the last active day before zeroing)
get_expiry_split_points <- function(valid_from, valid_until, policy_params) {
  if (is.null(policy_params)) return(as.Date(character()))

  adjustments <- collect_expiry_adjustments(policy_params)
  split_dates <- as.Date(character())

  for (adj in adjustments) {
    exp <- as.Date(adj$expiry_date)
    if (valid_from <= exp && valid_until > exp) {
      split_dates <- c(split_dates, exp)
    }
  }

  # Activation (turn-on) split points. An activation at A contributes A - 1, the
  # last INACTIVE day, so a new sub-interval opens exactly at A — mirroring the
  # expiry convention where the split point is the last ACTIVE day.
  for (adj in collect_activation_adjustments(policy_params)) {
    act <- as.Date(adj$activation_date)
    last_inactive <- act - 1
    if (valid_from <= last_inactive && valid_until > last_inactive) {
      split_dates <- c(split_dates, last_inactive)
    }
  }

  return(sort(unique(split_dates)))
}


#' Apply expiry zeroing to a snapshot for a given sub-interval
#'
#' Given a sub-interval start date, zeros any columns whose expiry_date < sub_start.
#'
#' @param rev_data Revision data tibble
#' @param sub_start Start date of the sub-interval
#' @param policy_params Policy params list
#' @return Adjusted rev_data
apply_expiry_zeroing <- function(rev_data, sub_start, policy_params) {
  if (is.null(policy_params)) return(rev_data)

  adjustments <- collect_expiry_adjustments(policy_params)

  for (adj in adjustments) {
    if (sub_start > adj$expiry_date && adj$column %in% names(rev_data)) {
      if (!is.null(adj$countries)) {
        rev_data <- rev_data %>%
          mutate(!!adj$column := if_else(country %in% adj$countries, 0, .data[[adj$column]]))
      } else {
        rev_data[[adj$column]] <- 0
      }
    }
  }

  # Activation gating: the rate is computed for the enclosing revision, so zero
  # it on sub-intervals that start BEFORE the duty legally takes effect.
  for (adj in collect_activation_adjustments(policy_params)) {
    if (sub_start < adj$activation_date && adj$column %in% names(rev_data)) {
      if (!is.null(adj$countries)) {
        rev_data <- rev_data %>%
          mutate(!!adj$column := if_else(country %in% adj$countries, 0, .data[[adj$column]]))
      } else {
        rev_data[[adj$column]] <- 0
      }
    }
  }

  return(rev_data)
}


# =============================================================================
# Point-in-Time Rate Query
# =============================================================================

#' Get rate snapshot at a specific date
#'
#' Filters the interval-encoded timeseries to rows where
#' valid_from <= query_date <= valid_until. Returns one revision's
#' worth of data (same shape as a single snapshot).
#'
#' Applies post-interval adjustments for any finalized=false policy overrides
#' (Section 122, Swiss framework) past their expiry dates.
#'
#' @param ts Timeseries tibble with valid_from/valid_until columns
#' @param query_date Date (or character coercible to Date)
#' @param policy_params Optional policy params list (from load_policy_params())
#' @return Tibble — one snapshot for the active revision at query_date
get_rates_at_date <- function(ts, query_date, policy_params = NULL) {
  query_date <- as.Date(query_date)

  # Load default policy params if not provided — ensures post-interval

  # adjustments (S122 expiry, Swiss framework) are applied consistently
  if (is.null(policy_params)) {
    policy_params <- tryCatch(load_policy_params(), error = function(e) NULL)
  }

  stopifnot(
    'valid_from' %in% names(ts),
    'valid_until' %in% names(ts)
  )

  snapshot <- ts %>%
    filter(valid_from <= query_date, valid_until >= query_date)

  if (nrow(snapshot) == 0) {
    warning('No rates found for date: ', query_date,
            '. Date range in timeseries: ',
            min(ts$valid_from), ' to ', max(ts$valid_until))
  }

  # Apply all date-bounded policy expirations
  snapshot <- apply_post_interval_adjustments_point(snapshot, query_date, policy_params)

  return(snapshot)
}
