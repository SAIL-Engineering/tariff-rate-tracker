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
# Note: source URLs are Federal Register SEARCH links keyed by title+citation
# (url_type 'fr_search'), not direct document links — labeled as such in the UI.
#
#   Rscript scripts/emit_revision_sources.R
# =============================================================================
suppressWarnings(suppressMessages({
  library(readr); library(dplyr); library(jsonlite); library(here)
}))

src_csv <- here('resources', 'tpc_policy_revision_map_usitc_archive_enriched.csv')
if (!file.exists(src_csv)) stop('Missing registry: ', src_csv)
d <- read_csv(src_csv, col_types = cols(.default = col_character()))

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
    list(
      title = if (k <= length(titles)) titles[k] else NULL,
      citation = if (k <= length(cites) && nzchar(cites[k])) cites[k] else NULL,
      url = if (k <= length(links)) links[k] else NULL,
      url_type = 'fr_search'
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
  note = 'Modification sources per USITC HTS archive; URLs are Federal Register search links (fr_search), not direct documents.',
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
