# =============================================================================
# emit_authority_contract.R — the frontend's authority registry
# =============================================================================
#
# Emits output/contract/authorities.json: one record per duty authority, giving
# the frontend its rate column, labels, grouping, statute and a resolvable
# citation URL.
#
# WHY THIS EXISTS
#
# A new duty program currently cannot reach the UI without a TypeScript change.
# `AuthorityKey` is a hardcoded union and `STATUTORY_KEY_MAP` is TOTAL over it,
# so adding a key breaks every consumer that switches on it — attempted during
# this work, it broke ~15 call sites. The result is that §301 forced labor,
# §301 Brazil, §338 and the per-action §232 split all exist in the data and are
# invisible in the interface.
#
# So the registry moves to data. The frontend reads this file, `AuthorityKey`
# becomes a runtime lookup rather than a union, and a new program becomes a
# config entry plus a reviewed citation — no R change, no TS change, and it
# renders with a working source link.
#
# Assembled from three sources that already exist, rather than a fourth list:
#   AUTHORITY_RATE_COLS      src/helpers.R    which columns exist at all
#   config/duty_citations.yaml                labels, statute, narrative
#   config/legal_reference.yaml               citation text + resolvable URL
#
# Usage:  Rscript src/emit_authority_contract.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(yaml)
  library(jsonlite)
  library(here)
})

if (!exists('AUTHORITY_RATE_COLS')) source(here('src', 'helpers.R'))

# --- rate column -> authority identity ---------------------------------------
# The one hand-maintained mapping, kept here because it encodes a legal
# grouping rather than a data fact: which statute each column answers to, and
# which columns are actions under a common authority.
AUTHORITY_CONTRACT <- tribble(
  ~key,                ~rate_column,          ~group,       ~label,                                  ~short_label,
  'section_232',       'rate_232',            'section_232','Section 232 (total)',                   '§232',
  's232_auto',         'rate_232_auto',       'section_232','Section 232 — Autos and Auto Parts',    '§232 Auto',
  's232_steel',        'rate_232_steel',      'section_232','Section 232 — Steel',                   '§232 Steel',
  's232_aluminum',     'rate_232_aluminum',   'section_232','Section 232 — Aluminum',                '§232 Aluminum',
  's232_copper',       'rate_232_copper',     'section_232','Section 232 — Copper',                  '§232 Copper',
  's232_other',        'rate_232_other',      'section_232','Section 232 — Other (wood, MHD, semiconductors)', '§232 Other',
  'section_301',       'rate_301',            'section_301','Section 301 — China',                   '§301',
  's301_forced_labor', 'rate_s301fl',         'section_301','Section 301 — Forced Labor (60 economies)', '§301 FL',
  's301_brazil',       'rate_s301br',         'section_301','Section 301 — Brazil',                  '§301 Brazil',
  'ieepa_reciprocal',  'rate_ieepa_recip',    'ieepa',      'IEEPA — Reciprocal',                    'IEEPA Recip',
  'ieepa_fentanyl',    'rate_ieepa_fent',     'ieepa',      'IEEPA — Border / Fentanyl',             'IEEPA Fent',
  'section_122',       'rate_s122',           'section_122','Section 122 — Balance of Payments',     '§122',
  'section_201',       'rate_section_201',    'section_201','Section 201 — Safeguards',              '§201',
  'section_338',       'rate_s338',           'section_338','Section 338 — Canada',                  '§338',
  'adcvd',             'rate_adcvd',          'adcvd',      'Antidumping / Countervailing Duty',     'AD/CVD',
  'other',             'rate_other',          'other',      'Other programs',                        'Other'
)

# Statute and citation per authority group.
GROUP_STATUTE <- c(
  section_232 = '19 U.S.C. 1862',
  section_301 = '19 U.S.C. 2411',
  ieepa       = '50 U.S.C. 1701 et seq.',
  section_122 = '19 U.S.C. 2132',
  section_201 = '19 U.S.C. 2251 et seq.',
  section_338 = '19 U.S.C. 1338',
  adcvd       = '19 U.S.C. 1673 / 1671',
  other       = NA_character_
)

# --- resolve citations --------------------------------------------------------
reg <- yaml::read_yaml(here('config', 'legal_reference.yaml'))$authorities %||% list()

cite_url <- function(a) {
  if (is.null(a)) return(NA_character_)
  if (!is.null(a$verified_against)) return(a$verified_against)
  if (!is.null(a$fr_document_number)) {
    return(paste0('https://www.federalregister.gov/d/', a$fr_document_number))
  }
  NA_character_
}

# Citation PER AUTHORITY, not per group. Pointing every §232 action at the
# steel proclamation would defeat the split: the whole reason the column was
# broken apart is that auto, steel, aluminum and copper are DISTINCT actions
# with distinct legal sources, and EO 14289 discriminates between them.
AUTHORITY_CITATION <- c(
  section_232       = 'proc_9705_steel',
  s232_auto         = 'proc_10908_autos_2025',
  s232_steel        = 'proc_9705_steel',
  s232_aluminum     = 'proc_9704_aluminum',
  s232_copper       = 'proc_10962_copper_2025',
  s232_other        = NA_character_,      # wood/MHD/semi: several proclamations
  section_301       = 's301_china_actions',
  s301_forced_labor = NA_character_,
  s301_brazil       = NA_character_,
  ieepa_reciprocal  = 'eo_14257_reciprocal',
  ieepa_fentanyl    = NA_character_,      # EO 14193/14194/14195, country-specific
  section_122       = 's122_balance_of_payments',
  section_201       = 's201_safeguards',
  section_338       = 'proc_11047_s338_canada',
  adcvd             = NA_character_,
  other             = NA_character_
)

# --- labels from duty_citations where they exist ------------------------------
dc <- yaml::read_yaml(here('config', 'duty_citations.yaml'))
dc_codes <- dc$reason_codes %||% dc

contract <- AUTHORITY_CONTRACT %>%
  mutate(
    present_in_schema = rate_column %in% AUTHORITY_RATE_COLS,
    statute = unname(GROUP_STATUTE[group]),
    citation_key = unname(AUTHORITY_CITATION[key]),
    citation_text = map_chr(citation_key, ~ if (is.na(.x)) NA_character_
                            else (reg[[.x]]$citation %||% NA_character_)),
    citation_url = map_chr(citation_key, ~ if (is.na(.x)) NA_character_
                           else cite_url(reg[[.x]]))
  )

# Every authority column in the schema must be described, or the frontend gets
# a rate it cannot name. This is the check that keeps the contract honest as
# AUTHORITY_RATE_COLS grows.
undescribed <- setdiff(AUTHORITY_RATE_COLS, AUTHORITY_CONTRACT$rate_column)
if (length(undescribed) > 0) {
  stop('Authority rate columns with no contract entry: ',
       paste(undescribed, collapse = ', '),
       '\n  Add them to AUTHORITY_CONTRACT in src/emit_authority_contract.R — ',
       'otherwise the frontend receives a rate column it cannot label.',
       call. = FALSE)
}
stale <- setdiff(AUTHORITY_CONTRACT$rate_column, AUTHORITY_RATE_COLS)
if (length(stale) > 0) {
  warning('Contract describes columns not in AUTHORITY_RATE_COLS: ',
          paste(stale, collapse = ', '), call. = FALSE)
}

out_dir <- here('output', 'contract')
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out_path <- file.path(out_dir, 'authorities.json')

payload <- list(
  schema_version = 1L,
  generated_from = 'AUTHORITY_RATE_COLS + config/duty_citations.yaml + config/legal_reference.yaml',
  note = paste('Authority registry for the frontend. AuthorityKey should be a',
               'runtime lookup over `authorities[].key`, not a compile-time union;',
               'an unrecognised key must fall back to its label here rather than',
               'throwing or rendering blank.'),
  authorities = contract %>%
    select(key, rate_column, group, label, short_label, statute,
           citation_key, citation_text, citation_url, present_in_schema)
)

write_json(payload, out_path, auto_unbox = TRUE, pretty = TRUE, na = 'null')
message('Wrote ', out_path, ' — ', nrow(contract), ' authorities, ',
        sum(!is.na(contract$citation_url)), ' with a resolvable citation URL')

invisible(payload)
