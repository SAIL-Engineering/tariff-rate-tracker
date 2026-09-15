#!/usr/bin/env Rscript
# =============================================================================
# Emit per-revision modification sources (JSON) for the frontends
# =============================================================================
# Source of truth: resources/tpc_policy_revision_map_usitc_archive_enriched.csv
# (USITC HTS archive Modification Source titles + FR citations + links per
# revision; provenance artifact maintained alongside config/revision_dates.csv).
# The frontend "Reasoning & sources" layer cites which legal actions each HTS
# revision implements, with links to validate authority and effective dates.
#
# Source URLs: older rows link a Federal Register SEARCH keyed by title +
# citation; rows filled from the archive listing by
# scripts/sync_usitc_archive.py link the FR document itself. url_type is derived
# from each URL ('fr_search' | 'fr_document' | 'web') so the UI labels it right.
#
#   Rscript scripts/emit_revision_sources.R
# =============================================================================
suppressWarnings(suppressMessages({
  library(readr); library(dplyr); library(jsonlite); library(here)
}))

src_csv <- here('resources', 'tpc_policy_revision_map_usitc_archive_enriched.csv')
if (!file.exists(src_csv)) stop('Missing registry: ', src_csv)
d <- read_csv(src_csv, col_types = cols(.default = col_character()))

# The map is kept alongside config/revision_dates.csv and once fell ten
# revisions behind unnoticed (2026_rev_8, 2026_rev_11-19). Say so loudly.
registry <- read_csv(here('config', 'revision_dates.csv'),
                     col_types = cols(.default = col_character()))
unmapped <- setdiff(registry$revision, d$revision)
if (length(unmapped) > 0) {
  warning('revisions in config/revision_dates.csv with no modification sources ',
          'in the map (', length(unmapped), '): ', paste(unmapped, collapse = ', '),
          '\n  Fill them with: python3 scripts/sync_usitc_archive.py sources',
          call. = FALSE)
}

url_type_of <- function(url) {
  if (is.null(url) || is.na(url) || !nzchar(url)) return(NULL)
  if (grepl('federalregister\\.gov/documents/search', url)) return('fr_search')
  if (grepl('federalregister\\.gov/', url)) return('fr_document')
  'web'
}

split_pipe <- function(x) {
  if (is.na(x) || !nzchar(x)) return(character(0))
  trimws(strsplit(x, '\\s*\\|\\s*')[[1]])
}

revisions <- list()
for (i in seq_len(nrow(d))) {
  r <- d[i, ]
  titles <- split_pipe(r$modification_source_titles)
  cites  <- split_pipe(r$modification_source_citations)
  links  <- split_pipe(r$federal_register_or_source_links)
  n <- max(length(titles), length(cites), length(links))
  sources <- lapply(seq_len(n), function(k) {
    url <- if (k <= length(links) && nzchar(links[k])) links[k] else NULL
    list(
      title = if (k <= length(titles)) titles[k] else NULL,
      citation = if (k <= length(cites) && nzchar(cites[k])) cites[k] else NULL,
      url = url,
      url_type = url_type_of(url)
    )
  })
  comm <- r$source_commentary
  revisions[[r$revision]] <- list(
    effective_date = r$effective_date,
    policy_effective_date = if (!is.na(r$policy_effective_date) &&
                                  r$policy_effective_date != 'NA')
      r$policy_effective_date else NULL,
    policy_family = if (!is.na(r$tpc_policy_revision) &&
                          r$tpc_policy_revision != 'NA')
      r$tpc_policy_revision else NULL,
    usitc_archive_url = r$usitc_archive_page_url,
    sources = sources,
    commentary = if (!is.na(comm) && comm != 'NA' && nzchar(comm)) comm else NULL,
    needs_review = identical(r$needs_review, 'review')
  )
}

out <- list(
  version = 1,
  generated_from = 'resources/tpc_policy_revision_map_usitc_archive_enriched.csv',
  note = 'Modification sources per USITC HTS archive. url_type says what each URL is: fr_document (the Federal Register document), fr_search (an FR search keyed by title + citation), or web.',
  revisions = revisions
)
json <- toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = 'null')

targets <- c(
  here('frontend', 'public', 'data', 'revision_sources.json'),
  file.path('/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease',
            'sail-gtx-prerelease/src/modules/tariff-rates/constants/revisionSources.json')
)
for (t in targets) {
  dn <- dirname(t)
  if (!dir.exists(dn)) {
    ok <- dir.create(dn, recursive = TRUE, showWarnings = FALSE)
    if (!ok) { cat('  skip (no dir):', t, '\n'); next }
  }
  writeLines(json, t)
  cat('  wrote:', t, '\n')
}
cat('Revision sources:', length(revisions), 'revisions\n')
