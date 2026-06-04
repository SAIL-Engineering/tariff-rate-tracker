#!/usr/bin/env Rscript
# =============================================================================
# Emit the frontend legalRefs bundle = machine-sourced (resources/ch99_legal_refs.csv,
# source='hts_note') + audited reference (config/legal_reference.yaml, source='reference').
# Re-run after src/extract_legal_refs.R to fill in the machine layer.
#   Rscript scripts/emit_legal_refs_json.R
# =============================================================================
suppressWarnings(suppressMessages({ library(tidyverse); library(yaml); library(jsonlite); library(here) }))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

# --- Machine layer: revision -> ch99 prefix -> {proclamations, eos, fr} ---
# Keyed by 7-char prefix (9903.94): every code under a note shares its authority.
machine <- list()
csv <- here('resources', 'ch99_legal_refs.csv')
if (file.exists(csv)) {
  d <- suppressMessages(read_csv(csv, show_col_types = FALSE))
  if (nrow(d) > 0) {
    splitc <- function(s) { x <- trimws(strsplit(s %||% '', ';')[[1]]); x[nzchar(x)] }
    d <- d %>% mutate(prefix = substr(ch99_code, 1, 7)) %>%
      distinct(revision, prefix, proclamations, executive_orders, fr_cites)
    for (rev in unique(d$revision)) {
      rd <- d %>% filter(revision == rev)
      # as.list() forces JSON arrays even for a single element (auto_unbox=TRUE
      # would otherwise collapse a length-1 vector to a bare string).
      machine[[rev]] <- setNames(lapply(seq_len(nrow(rd)), function(i) list(
        proclamations = as.list(splitc(rd$proclamations[i])),
        executive_orders = as.list(splitc(rd$executive_orders[i])),
        fr = as.list(splitc(rd$fr_cites[i]))
      )), rd$prefix)
    }
  }
}

# --- Reference layer ---
# reference: reason_code -> ARRAY of authority entries (a reason can have a
#   founding authority + later modifiers, e.g. s232_steel: 9705, 10896, ...).
# authorities: id -> entry (resolves termination_authority links and entries
#   with empty applies_to, e.g. CBP CSMS messages, civil aircraft GN 6).
ref_yaml <- yaml::read_yaml(here('config', 'legal_reference.yaml'))
ref_fields <- c('citation', 'statute', 'federal_register', 'fr_document_number',
                'signed_date', 'publication_date', 'effective_date', 'agency',
                'hts_reference', 'secondary_reference', 'verified_against',
                'verification_scope', 'status_note', 'termination_authority',
                'source_status', 'requires_post_publication_recheck')
reference  <- list()
authorities <- list()
for (id in names(ref_yaml$authorities)) {
  a <- ref_yaml$authorities[[id]]
  entry <- list(id = id, verified = isTRUE(a$verified))
  for (f in ref_fields) if (!is.null(a[[f]])) entry[[f]] <- a[[f]]
  authorities[[id]] <- entry
  for (reason in (a$applies_to %||% character(0))) {
    reference[[reason]] <- c(reference[[reason]], list(entry))
  }
}

# --- IEEPA refund/recovery layer (4-layer status model: duty authority ->
#     ended-collection status -> refund process -> litigation risk). Carried
#     verbatim from config so the frontend renders precise, legally-cautious copy
#     in the Flags and "why SAIL differs from broker" sections. ---
ieepa_refund <- ref_yaml$ieepa_refund %||% NULL

out <- list(
  version = 2,
  machine_source = 'hts_note', reference_source = 'reference',
  machine = machine, reference = reference, authorities = authorities,
  ieepa_refund = ieepa_refund
)
json <- toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = 'null', na = 'null')

targets <- c(
  here('frontend', 'public', 'data', 'legal_refs.json'),
  file.path('/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease',
            'sail-gtx-prerelease/src/modules/tariff-rates/constants/legalRefs.json')
)
for (t in targets) {
  d <- dirname(t)
  if (dir.exists(d) || dir.create(d, recursive = TRUE, showWarnings = FALSE)) {
    writeLines(json, t); cat('  wrote:', t, '\n')
  } else cat('  skip (no dir):', t, '\n')
}
cat('legalRefs: ', length(machine), ' revisions machine-sourced, ',
    length(reference), ' reasons referenced\n', sep = '')
