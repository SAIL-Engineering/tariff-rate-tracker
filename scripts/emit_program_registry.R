#!/usr/bin/env Rscript
# =============================================================================
# Emit the frontend program registry (JSON) from reviewed config
# =============================================================================
# Builds program_registry.json — the data-driven program list the frontend
# renders instead of a hardcoded AUTHORITIES array. Sources:
#   * config/duty_citations.yaml      — authority labels + legal anchors
#   * config/ch99_source_registry.yaml — program-family -> FR/CSMS/quota sources
#
# Programs not in the frontend's seven scalar rate columns (mtb_9902,
# ag_safeguard_9904, trade_deal_modifier) render generically from this
# registry via ch99_rules_json entries. Run whenever either YAML changes:
#
#   Rscript scripts/emit_program_registry.R
# =============================================================================
suppressWarnings(suppressMessages({ library(yaml); library(jsonlite); library(here) }))

`%||%` <- function(a, b) if (is.null(a)) b else a

cit <- yaml::read_yaml(here('config', 'duty_citations.yaml'))
reg <- yaml::read_yaml(here('config', 'ch99_source_registry.yaml'))

fam <- reg$program_families %||% list()

fam_urls <- function(key) {
  f <- fam[[key]]
  if (is.null(f)) return(NULL)
  unlist(f$urls %||% list())
}

# Program key -> { label, statute/anchor, ch99 prefixes, rate column (if any),
# source registry families }. Keys match the `authority` field emitted in
# ch99_rules_json (upstream AuthoritySpec vocabulary).
programs <- list(
  section_232 = list(
    label = 'Section 232',
    anchor = cit$authorities[['232']]$anchor,
    rate_column = 'rate_232',
    ch99_prefixes = c('9903.74', '9903.76', '9903.78', '9903.79',
                      '9903.80', '9903.81', '9903.82', '9903.83',
                      '9903.84', '9903.85', '9903.94'),
    families = c('section_232_steel_aluminum_copper_metals',
                 'section_232_autos_light_vehicles_parts',
                 'section_232_mhdv_parts_buses',
                 'section_232_timber_lumber_wood_derivatives',
                 'section_232_semiconductors',
                 'section_232_pharmaceuticals')
  ),
  section_301 = list(
    label = 'Section 301',
    anchor = cit$authorities[['301']]$anchor,
    rate_column = 'rate_301',
    ch99_prefixes = c('9903.88', '9903.91', '9903.92'),
    families = 'section_301_china'
  ),
  ieepa_reciprocal = list(
    label = 'IEEPA Reciprocal',
    anchor = cit$authorities$ieepa_recip$anchor,
    rate_column = 'rate_ieepa_recip',
    ch99_prefixes = c('9903.01.25-9903.01.99', '9903.02'),
    families = c('ieepa_reciprocal', 'ieepa_brazil', 'ieepa_india_russian_oil')
  ),
  ieepa_fentanyl = list(
    label = 'Anti-Fentanyl (IEEPA)',
    anchor = cit$authorities$ieepa_fent$anchor,
    rate_column = 'rate_ieepa_fent',
    ch99_prefixes = '9903.01.01-9903.01.24',
    families = 'ieepa_fentanyl_canada_mexico_china'
  ),
  section_122 = list(
    label = 'Section 122',
    anchor = cit$authorities$s122$anchor,
    rate_column = 'rate_s122',
    ch99_prefixes = '9903.03',
    families = 'section_122_temporary_import_surcharge'
  ),
  section_201 = list(
    label = 'Section 201 Safeguard',
    anchor = cit$authorities$section_201$anchor,
    rate_column = 'rate_section_201',
    ch99_prefixes = '9903.40-9903.45',
    families = 'section_201_global_safeguards'
  ),
  mtb_9902 = list(
    label = 'MTB Temporary Suspension (9902)',
    anchor = 'American Manufacturing Competitiveness Act; HTSUS ch. 99 subch. II',
    rate_column = NULL,
    ch99_prefixes = '9902',
    families = 'mtb_9902_temporary_duty_suspensions',
    note = 'Temporary duty REDUCTION/suspension; candidate status only — not yet integrated into rate math.'
  ),
  ag_safeguard_9904 = list(
    label = 'Agricultural Safeguard / TRQ (9904)',
    anchor = 'HTSUS ch. 99 subch. IV; Additional U.S. Notes; CBP quota bulletins',
    rate_column = NULL,
    ch99_prefixes = '9904',
    families = c('agriculture_safeguards_9904_trq',
                 'fta_preference_trq_chapter_99_subchapters'),
    note = 'Quota-tier duty; requires quota period/fill facts — candidate status only.'
  ),
  trade_deal_modifier = list(
    label = 'Trade-Deal / Civil-Aircraft Modifier',
    anchor = 'Country-deal implementing FR notices; General Note 6 (civil aircraft)',
    rate_column = NULL,
    ch99_prefixes = '9903.96',
    families = 'civil_aircraft_country_deal_modifiers'
  ),
  russia_belarus_ntr = list(
    label = 'Russia/Belarus NTR Suspension (Column 2)',
    anchor = 'Suspending Normal Trade Relations with Russia and Belarus Act',
    rate_column = 'rate_column2',
    ch99_prefixes = character(0),
    families = 'russia_belarus_ntr_suspension'
  )
)

for (key in names(programs)) {
  fams <- programs[[key]]$families
  programs[[key]]$sources <- unique(unlist(lapply(fams, fam_urls)))
}

out <- list(
  version = 1,
  generated_from = c('config/duty_citations.yaml', 'config/ch99_source_registry.yaml'),
  stack_order = cit$stack_order,
  statuses = c('applied', 'exempt_or_replaced', 'not_applicable',
               'potentially_applicable_requires_more_facts'),
  programs = programs
)

json <- jsonlite::toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = 'null')
targets <- c(
  here('frontend', 'public', 'data', 'program_registry.json'),
  file.path('/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease',
            'sail-gtx-prerelease/src/modules/tariff-rates/constants/programRegistry.json')
)
for (t in targets) {
  d <- dirname(t)
  if (!dir.exists(d)) {
    ok <- dir.create(d, recursive = TRUE, showWarnings = FALSE)
    if (!ok) { cat('  skip (no dir):', t, '\n'); next }
  }
  writeLines(json, t)
  cat('  wrote:', t, '\n')
}
cat('Program registry:', length(programs), 'programs\n')
