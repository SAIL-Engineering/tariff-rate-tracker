# =============================================================================
# validate_citations.R — citation integrity across the whole pipeline
# =============================================================================
#
# Every piece of derived tariff logic must trace to a primary source the frontend
# can LINK to: an Executive Order, a Proclamation, a Federal Register notice, CBP
# CSMS guidance, an HTS General Note, or a Commerce AD/CVD case.
#
# `config/legal_reference.yaml` is the registry. Everything else — stacking rules,
# duty reason codes, Ch99 legal refs, revision sources, AD/CVD orders — refers to
# it by `citation_key`. This script proves those references resolve, so a rule can
# never silently ship without a citation, and the frontend can never be handed a
# dangling reference.
#
# Checks:
#   C1  dangling      a citation_key referenced somewhere but not registered
#   C2  unlinkable    a registered authority with no resolvable URL
#   C3  unverified    registered but verified: false (needs legal review)
#   C4  orphan        registered but never referenced (informational)
#   C5  bare_cite     free-text `citation:` where a citation_key is expected
#   C6  stale_pending an entry still flagged pending publication / recheck
#   C7  weak_link     `verified_against` points at a search or index page rather
#                     than a specific document — linkable but not a citation
#
# Usage:
#   Rscript src/validate_citations.R            # report
#   Rscript src/validate_citations.R --strict   # non-zero exit on C1/C2
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(yaml)
  library(here)
})

.strict <- '--strict' %in% commandArgs(trailingOnly = TRUE)

# --- the registry ------------------------------------------------------------
ref_path <- here('config', 'legal_reference.yaml')
if (!file.exists(ref_path)) stop('legal_reference.yaml not found: ', ref_path)

# A duplicate map key silently drops one of the two definitions in most YAML
# readers, so it must fail loudly and legibly rather than as a raw traceback.
registry_doc <- tryCatch(
  yaml::read_yaml(ref_path),
  error = function(e) {
    msg <- conditionMessage(e)
    if (grepl('Duplicate map key', msg, fixed = TRUE)) {
      stop('legal_reference.yaml has a DUPLICATE KEY — one definition would be ',
           'silently dropped. Fix it before any citation can be trusted.\n  ', msg,
           call. = FALSE)
    }
    stop('legal_reference.yaml is unparseable:\n  ', msg, call. = FALSE)
  })
registry <- registry_doc$authorities %||% list()
registered <- names(registry)

message('Citation registry: ', length(registered), ' authorities')

# A citation is LINKABLE if it carries something the frontend can turn into a
# URL: an explicit verified_against link, or an FR document number we can build a
# federalregister.gov URL from.
fr_url <- function(a) {
  if (!is.null(a$verified_against)) return(a$verified_against)
  if (!is.null(a$fr_document_number)) {
    return(paste0('https://www.federalregister.gov/d/', a$fr_document_number))
  }
  NA_character_
}

reg_tbl <- tibble(
  key      = registered,
  url      = map_chr(registry, fr_url),
  fr       = map_chr(registry, ~ .x$federal_register %||% NA_character_),
  verified = map_lgl(registry, ~ isTRUE(.x$verified)),
  scope    = map_chr(registry, ~ .x$verification_scope %||% NA_character_),
  pending  = map_lgl(registry, ~ isTRUE(.x$requires_post_publication_recheck) ||
                       grepl('pending', .x$source_status %||% '', ignore.case = TRUE)),
  # An authority that IS a multi-notice program rather than one document may
  # opt out of C7, but only with a written reason.
  is_index = map_lgl(registry, ~ isTRUE(.x$link_is_index))
)

# --- collect every reference -------------------------------------------------
# YAML: any `citation_key` / `citation_keys` at any depth.
collect_keys_yaml <- function(x, src, acc = list()) {
  if (is.list(x)) {
    for (nm in names(x)) {
      if (nm %in% c('citation_key', 'citation_keys')) {
        v <- x[[nm]]
        v <- v[!vapply(v, is.null, logical(1))]
        for (k in unlist(v)) {
          acc[[length(acc) + 1L]] <- tibble(key = as.character(k), source = src)
        }
      }
    }
    for (el in x) acc <- collect_keys_yaml(el, src, acc)
  }
  acc
}

yaml_sources <- c('config/stacking_rules.yaml', 'config/duty_citations.yaml',
                  'config/ch99_source_registry.yaml', 'config/policy_params.yaml',
                  'config/program_requirements.yaml')
refs <- list()
for (f in yaml_sources) {
  p <- here(f)
  if (!file.exists(p)) next
  y <- tryCatch(yaml::read_yaml(p), error = function(e) NULL)
  if (is.null(y)) { message('  WARN: unparseable YAML, skipped: ', f); next }
  refs <- c(refs, collect_keys_yaml(y, f))
}

# CSVs: a `citation_key` column (AD/CVD orders and rates use this).
csv_sources <- c('resources/ch99_legal_refs.csv', 'resources/adcvd_orders.csv',
                 'resources/adcvd_rates.csv')
for (f in csv_sources) {
  p <- here(f)
  if (!file.exists(p)) next
  d <- tryCatch(suppressMessages(read_csv(p, show_col_types = FALSE)),
                error = function(e) NULL)
  if (is.null(d) || !'citation_key' %in% names(d)) next
  refs[[length(refs) + 1L]] <- tibble(key = as.character(d$citation_key), source = f)
}

referenced <- if (length(refs)) bind_rows(refs) %>% filter(!is.na(key), nzchar(key)) else
  tibble(key = character(), source = character())

message('References found: ', nrow(referenced), ' across ',
        n_distinct(referenced$source), ' file(s)')

# --- checks ------------------------------------------------------------------
findings <- list()
add <- function(check, severity, detail) {
  findings[[length(findings) + 1L]] <<- tibble(check = check, severity = severity,
                                               detail = detail)
}

# C1 — dangling references
dangling <- referenced %>% filter(!key %in% registered) %>% distinct(key, source)
for (i in seq_len(nrow(dangling))) {
  add('C1_dangling', 'ERROR',
      sprintf('%s references unregistered citation_key "%s"',
              dangling$source[i], dangling$key[i]))
}

# C2 — registered but not linkable (the frontend needs a URL)
unlinkable <- reg_tbl %>% filter(is.na(url))
for (k in unlinkable$key) {
  add('C2_unlinkable', 'ERROR',
      sprintf('authority "%s" has no verified_against URL and no fr_document_number — cannot be linked in the UI', k))
}

# C3 — unverified
for (i in which(!reg_tbl$verified)) {
  add('C3_unverified', 'WARN',
      sprintf('authority "%s" is verified: false (%s)', reg_tbl$key[i],
              if (is.na(reg_tbl$scope[i])) 'no scope note' else reg_tbl$scope[i]))
}

# C4 — orphans (informational: registered but nothing points at it)
orphans <- setdiff(registered, unique(referenced$key))
if (length(orphans) > 0) {
  add('C4_orphan', 'INFO',
      sprintf('%d registered authorities are never referenced by a citation_key: %s',
              length(orphans), paste(utils::head(orphans, 8), collapse = ', ')))
}

# C5 — free-text citations in stacking rules, where a key is expected
sp <- here('config', 'stacking_rules.yaml')
if (file.exists(sp)) {
  bare <- grep("^\\s*citation:\\s*['\"]", readLines(sp, warn = FALSE), value = TRUE)
  for (b in bare) {
    add('C5_bare_cite', 'WARN',
        sprintf('stacking_rules.yaml uses free-text citation instead of citation_key: %s',
                trimws(b)))
  }
}

# C6 — still flagged pending publication / recheck.
# A public-inspection document publishes within days, so this flag going stale is
# the normal case, not the exception: proc_11032 sat "pending" for two months
# after it had in fact published at 91 FR 34085.
for (k in reg_tbl$key[reg_tbl$pending]) {
  add('C6_stale_pending', 'WARN',
      sprintf('authority "%s" is still flagged pending publication/recheck — re-query the Federal Register API and clear the flag', k))
}

# C7 — "linkable" to a search page is not a citation. These pass C2 while giving
# the frontend a link that does not identify the document.
weak_patterns <- c('/documents/search', '/presidential-documents/executive-orders$',
                   '/presidential-documents$', 'hts\\.usitc\\.gov/?$',
                   '\\?conditions', 'ustr\\.gov/issue-areas')
for (i in which(!is.na(reg_tbl$url) & !reg_tbl$is_index)) {
  if (any(vapply(weak_patterns, grepl, logical(1), x = reg_tbl$url[i]))) {
    add('C7_weak_link', 'WARN',
        sprintf('authority "%s" links to a search/index page, not a specific document: %s',
                reg_tbl$key[i], reg_tbl$url[i]))
  }
}

# An index opt-out without a written reason is itself a finding.
for (k in reg_tbl$key[reg_tbl$is_index]) {
  if (!nzchar(registry[[k]]$link_is_index_reason %||% '')) {
    add('C7_weak_link', 'WARN',
        sprintf('authority "%s" sets link_is_index without link_is_index_reason', k))
  }
}

# --- report ------------------------------------------------------------------
out <- if (length(findings)) bind_rows(findings) else
  tibble(check = character(), severity = character(), detail = character())

message('\n', strrep('=', 70))
if (nrow(out) == 0) {
  message('Citation integrity: OK — every reference resolves and is linkable.')
} else {
  for (sev in c('ERROR', 'WARN', 'INFO')) {
    sub <- out %>% filter(severity == sev)
    if (nrow(sub) == 0) next
    message('\n', sev, ' (', nrow(sub), ')')
    for (i in seq_len(nrow(sub))) message('  [', sub$check[i], '] ', sub$detail[i])
  }
}
message(strrep('=', 70))

dir.create(here('output', 'quality'), recursive = TRUE, showWarnings = FALSE)
readr::write_csv(out, here('output', 'quality', 'citation_integrity.csv'))
message('Wrote output/quality/citation_integrity.csv')

n_err <- sum(out$severity == 'ERROR')
message('ERRORS: ', n_err, '  WARNINGS: ', sum(out$severity == 'WARN'))
if (.strict && n_err > 0) quit(status = 1)
