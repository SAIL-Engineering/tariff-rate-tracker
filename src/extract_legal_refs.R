# =============================================================================
# Per-revision legal-authority extraction (Chapter 99 U.S. Notes)
# =============================================================================
# MACHINE-SOURCES the legal basis of each duty authority from the HTS itself:
# for each revision it pulls that release's Chapter 99 U.S. Notes PDF, extracts
# the proclamations / executive orders / Federal Register cites each note cites,
# and maps them to the ch99 headings the note governs (from the line
# descriptions). Output is tagged source = 'hts_note' — verifiable, not curated.
#
# MAINTAINABILITY: keyed off the USITC release name (release=<id> reststop file
# endpoint), so when a new revision is downloaded and the timeseries build runs,
# its Chapter 99 PDF is fetched and extracted automatically — no per-revision
# hand work. Build_legal_refs_for_revision() is called from the build loop; the
# standalone CLI at the bottom does a one-time historical backfill.
#
# COVERAGE: the reststop per-release file endpoint serves ~2022→current. Older
# releases (2019-2021) return an HTML error, not a PDF — those revisions get no
# hts_note rows and fall back to the audited reference layer
# (config/legal_reference.yaml). download_chapter99_pdf_cached() returns NULL on
# any non-PDF response, so the build degrades gracefully.
#
# Depends on: pdftools, tidyverse, here; build_chapter99_url() from helpers.R.
# =============================================================================

#' Map a tracker revision id to the USITC API release name.
#' '2026_rev_9' -> '2026HTSRev9'; '2026_basic' -> '2026HTSBasic';
#' 'rev_5' -> '2025HTSRev5'; 'basic' -> '2025HTSBasic' (2025 carries no year prefix).
revision_to_release_name <- function(revision) {
  m <- regmatches(revision, regexec('^([0-9]{4})_(.*)$', revision))[[1]]
  if (length(m) == 3) { yr <- m[2]; rest <- m[3] } else { yr <- '2025'; rest <- revision }
  if (rest == 'basic') return(paste0(yr, 'HTSBasic'))
  paste0(yr, 'HTSRev', sub('^rev_', '', rest))
}

#' Download a release's Chapter 99 PDF (cached per revision). Returns the path,
#' or NULL when the release is not served as a PDF (older releases return HTML).
download_chapter99_pdf_cached <- function(revision,
                                          dest_dir = here::here('data', 'us_notes'),
                                          force = FALSE) {
  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(dest_dir, paste0('chapter99_', revision, '.pdf'))
  if (!force && file.exists(path) && file.info(path)$size > 1e6) return(path)
  if (!exists('build_chapter99_url', mode = 'function')) {
    stop('build_chapter99_url() not found — source src/helpers.R first.')
  }
  url <- build_chapter99_url(revision_to_release_name(revision))
  ok <- tryCatch({ utils::download.file(url, path, mode = 'wb', quiet = TRUE); TRUE },
                 error = function(e) FALSE)
  if (!ok || !file.exists(path)) return(NULL)
  # Reject HTML error pages (older releases) — keep only real PDFs.
  magic <- tryCatch(rawToChar(readBin(path, 'raw', 4)), error = function(e) '')
  if (!identical(magic, '%PDF')) { unlink(path); return(NULL) }
  path
}

#' Parse the Subchapter III U.S. Notes of a Chapter 99 PDF into
#' note -> {proclamations, executive_orders, fr_cites}.
extract_note_legal_refs <- function(pdf_path) {
  if (!requireNamespace('pdftools', quietly = TRUE)) stop('pdftools package required')
  txt   <- paste(pdftools::pdf_text(pdf_path), collapse = '\n')
  lines <- strsplit(txt, '\n')[[1]]
  # Subchapter III duty notes begin at this sentinel; fall back to all text.
  start <- grep('This subchapter contains the temporary modifications', lines)[1]
  if (is.na(start)) start <- 1L
  sub3 <- lines[start:length(lines)]

  is_hdr  <- grepl('^\\s{0,10}[0-9]{1,2}\\.\\s', sub3)
  hdr_num <- ifelse(is_hdr, suppressWarnings(as.integer(sub('^\\s*([0-9]{1,2})\\..*', '\\1', sub3))), NA_integer_)
  blk     <- cumsum(is_hdr)
  refs    <- function(t, p) paste(unique(unlist(regmatches(t, gregexpr(p, t)))), collapse = '; ')

  out <- lapply(split(seq_along(sub3), blk), function(idx) {
    t <- paste(sub3[idx], collapse = ' ')
    tibble::tibble(
      note               = hdr_num[idx][!is.na(hdr_num[idx])][1],
      proclamations      = refs(t, 'Proclamation [0-9]{4,5}'),
      executive_orders   = refs(t, 'Executive Order [0-9]{4,5}'),
      fr_cites           = refs(t, '[0-9]{1,3} FR [0-9]{3,6}')
    )
  })
  dplyr::bind_rows(out) %>%
    dplyr::filter(!is.na(note),
                  nchar(proclamations) > 0 | nchar(executive_orders) > 0 | nchar(fr_cites) > 0) %>%
    # If a note number appears twice (multi-subchapter), keep the richest block.
    dplyr::group_by(note) %>%
    dplyr::slice_max(nchar(proclamations) + nchar(executive_orders) + nchar(fr_cites), n = 1, with_ties = FALSE) %>%
    dplyr::ungroup()
}

#' Map each ch99 code to the U.S. Note that governs it, from the parsed
#' descriptions ("...as provided for in U.S. note N to this subchapter").
extract_ch99_note_map <- function(ch99_data) {
  if (!'description' %in% names(ch99_data)) return(tibble::tibble())
  note_of <- function(d) {
    m <- regmatches(d, regexpr('U\\.S\\. note\\s+[0-9]+', d, ignore.case = TRUE))
    if (length(m) == 0) return(NA_integer_)
    suppressWarnings(as.integer(sub('.*?([0-9]+).*', '\\1', m)))
  }
  ch99_data %>%
    dplyr::transmute(ch99_code, note = vapply(description %||% '', note_of, integer(1))) %>%
    dplyr::filter(!is.na(note)) %>%
    dplyr::distinct()
}

#' Build the per-revision ch99 -> legal-authority table (source = 'hts_note').
#' Returns an empty tibble (not NULL) when the release has no PDF, so callers
#' can rbind unconditionally.
build_legal_refs_for_revision <- function(revision, ch99_data) {
  empty <- tibble::tibble(revision = character(), ch99_code = character(), note = integer(),
                          proclamations = character(), executive_orders = character(),
                          fr_cites = character(), source = character())
  pdf <- tryCatch(download_chapter99_pdf_cached(revision), error = function(e) NULL)
  if (is.null(pdf)) {
    message('  [legal_refs] no per-release PDF for ', revision, ' (pre-~2022 or unavailable) — skipped')
    return(empty)
  }
  note_refs <- tryCatch(extract_note_legal_refs(pdf), error = function(e) NULL)
  ch99_note <- extract_ch99_note_map(ch99_data)
  if (is.null(note_refs) || nrow(note_refs) == 0 || nrow(ch99_note) == 0) return(empty)
  ch99_note %>%
    dplyr::inner_join(note_refs, by = 'note') %>%
    dplyr::mutate(revision = revision, source = 'hts_note') %>%
    dplyr::select(revision, ch99_code, note, proclamations, executive_orders, fr_cites, source)
}

#' Discover ch99 caches (revision -> cache path), preferring year-prefixed names.
.discover_ch99_caches_lr <- function() {
  dirs <- c(here::here('data', 'timeseries'), here::here('data', 'processed'))
  files <- unlist(lapply(dirs, function(d)
    if (dir.exists(d)) list.files(d, pattern = '^ch99_.*\\.rds$', full.names = TRUE) else character(0)))
  if (length(files) == 0) return(setNames(character(0), character(0)))
  rev <- gsub('^ch99_|\\.rds$', '', basename(files))
  keep <- !duplicated(rev)            # first wins; year-prefixed dirs listed first
  setNames(files[keep], rev[keep])
}

#' INCREMENTAL emitter — the maintainable entry point. Reads the existing
#' resources/ch99_legal_refs.csv, processes ONLY revisions not already in it
#' (downloading + extracting each revision's Chapter 99 PDF, cached), and
#' appends. So a build that adds a new revision extracts only that revision's
#' legal refs; nothing is re-downloaded. Revisions with no per-release PDF
#' (pre-2024) contribute no rows and are retried cheaply next time.
emit_legal_refs_incremental <- function(output_csv = here::here('resources', 'ch99_legal_refs.csv'),
                                        only = NULL, force = FALSE) {
  existing <- if (file.exists(output_csv) && !force)
    suppressMessages(readr::read_csv(output_csv, show_col_types = FALSE)) else NULL
  done <- if (!is.null(existing) && 'revision' %in% names(existing)) unique(existing$revision) else character(0)

  caches <- .discover_ch99_caches_lr()
  revs <- names(caches)
  if (!is.null(only)) revs <- revs[revs %in% only]
  todo <- setdiff(revs, done)
  if (length(todo) == 0) {
    message('  [legal_refs] up to date (', length(done), ' revisions covered)')
    return(invisible(existing))
  }

  new_rows <- purrr::map_dfr(todo, function(rev) {
    ch99 <- tryCatch(readRDS(caches[[rev]]), error = function(e) NULL)
    if (is.null(ch99)) return(tibble::tibble())
    out <- build_legal_refs_for_revision(rev, ch99)
    if (nrow(out) > 0) {
      np <- length(unique(unlist(strsplit(paste(out$proclamations, collapse = '; '), '; '))))
      message('  [legal_refs] ', rev, ': ', dplyr::n_distinct(out$ch99_code),
              ' codes, ', np, ' distinct proclamation(s)')
    }
    out
  })

  all <- dplyr::bind_rows(existing, new_rows)
  if (nrow(all) > 0) all <- dplyr::distinct(all, revision, ch99_code, .keep_all = TRUE)
  if (!dir.exists(dirname(output_csv))) dir.create(dirname(output_csv), recursive = TRUE)
  readr::write_csv(all, output_csv)
  message('  [legal_refs] ch99_legal_refs.csv: +', nrow(new_rows), ' rows from ',
          length(todo), ' new revision(s) (', dplyr::n_distinct(all$revision),
          ' revisions, ', nrow(all), ' rows total)')
  invisible(all)
}

# -----------------------------------------------------------------------------
# Standalone CLI: backfill across all (cached) revisions, incrementally.
#   Rscript src/extract_legal_refs.R [--only-revisions 2024,2025,2026] [--force]
# -----------------------------------------------------------------------------
if (sys.nframe() == 0) {
  suppressWarnings(suppressMessages({ library(tidyverse); library(here) }))
  source(here('src', 'logging.R'))
  source(here('src', 'helpers.R'))
  source(here('src', 'scrape_us_notes.R'))
  source(here('src', '03_parse_chapter99.R'))

  args  <- commandArgs(trailingOnly = TRUE)
  force <- '--force' %in% args
  only  <- NULL
  oi <- match('--only-revisions', args)
  if (!is.na(oi) && oi < length(args)) {
    tokens <- strsplit(args[oi + 1], ',')[[1]]
    all_revs <- read_csv(here('config', 'revision_dates.csv'), show_col_types = FALSE)$revision
    only <- all_revs[vapply(all_revs, function(r)
      any(r == tokens | startsWith(r, paste0(tokens, '_')) | startsWith(r, tokens)), logical(1))]
  }
  res <- emit_legal_refs_incremental(only = only, force = force)
  cat('Done. ', if (is.null(res)) 0 else nrow(res), ' rows in resources/ch99_legal_refs.csv\n', sep = '')
}
