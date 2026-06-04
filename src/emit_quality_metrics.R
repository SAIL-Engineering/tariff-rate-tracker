# =============================================================================
# Quality / Metric Artifact Emitter
# =============================================================================
# Regenerates the QA metrics in output/quality/ on EVERY timeseries build so
# they never go stale. Pure read/derive — safe to re-run any time, in any build
# mode (full, resume, scoped, build-only).
#
# Design notes (why this is robust):
#   * Re-derives resolution_status with the CURRENT classifier instead of
#     trusting the label baked into each ch99 cache. A classifier fix takes
#     effect on the next emit without a full re-parse.
#   * Covers ALL ch99 caches on disk (every year/revision), not just the subset
#     a given build touched.
#   * Writes output/quality/metrics_manifest.csv with a generated_at timestamp
#     and per-artifact row/revision counts, so staleness is visible at a glance.
#
# Depends on: tidyverse, here, and classify_resolution_status() (src/03).
# =============================================================================

#' Discover ch99 caches across the processed + timeseries dirs, preferring the
#' year-prefixed canonical name (ch99_2025_rev_5.rds) over the legacy short one
#' (ch99_rev_5.rds) when both exist for a revision.
.discover_ch99_caches <- function() {
  dirs <- c(here::here('data', 'processed'), here::here('data', 'timeseries'))
  files <- unlist(lapply(dirs, function(d) {
    if (dir.exists(d)) list.files(d, pattern = '^ch99_.*\\.rds$', full.names = TRUE) else character(0)
  }))
  if (length(files) == 0) return(character(0))
  rev_key <- gsub('^ch99_|\\.rds$', '', basename(files))
  # Prefer year-prefixed (starts with 4 digits) for a given revision token.
  is_year <- grepl('^[0-9]{4}_', rev_key)
  short_token <- sub('^[0-9]{4}_', '', rev_key)
  keep <- rep(TRUE, length(files))
  for (tok in unique(short_token[is_year])) {
    legacy <- which(short_token == tok & !is_year)
    if (length(legacy) > 0) keep[legacy] <- FALSE
  }
  files[keep]
}

#' Regenerate the Chapter 99 country-scope triage CSV from all ch99 caches.
#'
#' @return The triage tibble (invisibly written to output/quality/).
emit_ch99_triage <- function(output_dir = here::here('output', 'quality')) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  files <- .discover_ch99_caches()
  if (length(files) == 0) {
    message('  [metrics] no ch99 caches found — triage skipped')
    return(invisible(tibble::tibble()))
  }

  has_classifier <- exists('classify_resolution_status', mode = 'function')
  all_triage <- purrr::map_dfr(files, function(f) {
    ch99 <- readRDS(f)
    rev <- gsub('^ch99_|\\.rds$', '', basename(f))
    if (!all(c('ch99_code', 'country_type') %in% names(ch99))) return(tibble::tibble())
    # Re-derive status with the CURRENT classifier (don't trust stale labels).
    if (has_classifier) {
      ch99$resolution_status <- classify_resolution_status(ch99$ch99_code, ch99$country_type)
    } else if (!'resolution_status' %in% names(ch99)) {
      ch99$resolution_status <- NA_character_
    }
    refs <- if ('references' %in% names(ch99)) {
      vapply(ch99$references, function(r) paste(r, collapse = '; '), character(1))
    } else rep(NA_character_, nrow(ch99))
    desc <- if ('description' %in% names(ch99)) ch99$description else NA_character_
    tibble::tibble(
      ch99_code = ch99$ch99_code, authority = ch99$authority %||% NA_character_,
      country_type = ch99$country_type, resolution_status = ch99$resolution_status,
      references = refs, description = desc, revision = rev
    ) %>% dplyr::filter(country_type == 'unknown')
  })

  readr::write_csv(all_triage, file.path(output_dir, 'ch99_country_scope_triage.csv'))
  # NB: "unknown-scope" just means parse_countries() couldn't tag the country —
  # most are still resolved by an extractor. The accurate breakdown (handled vs
  # rated-but-unmodeled vs TRULY unresolved) prints in the resolution summary.
  message('  [metrics] ch99_country_scope_triage.csv: ', nrow(all_triage),
          ' unknown-scope entries across ', dplyr::n_distinct(all_triage$revision), ' revisions')
  invisible(all_triage)
}

#' Reconciliation — the HONEST "actually-resolved" check.
#'
#' A ch99 code being in a "handled" range is not the same as SAIL applying its
#' rate. This lists codes that parse a real duty RATE (> 0) but land in an
#' `unresolved` bucket — i.e. SAIL may UNDER-COLLECT them (e.g. the legacy
#' Section 201 / retaliation codes at 25–100%). Cheap: reads ch99 caches only.
emit_rate_reconciliation <- function(output_dir = here::here('output', 'quality')) {
  files <- .discover_ch99_caches()
  empty <- tibble::tibble(ch99_code = character(), authority = character(),
                          max_rate = numeric(), revisions = integer(),
                          first_revision = character(), last_revision = character(),
                          resolution_status = character(), description = character())
  if (length(files) == 0) return(invisible(empty))
  has_classifier <- exists('classify_resolution_status', mode = 'function')
  recon <- purrr::map_dfr(files, function(f) {
    ch99 <- readRDS(f); rev <- gsub('^ch99_|\\.rds$', '', basename(f))
    if (!all(c('ch99_code', 'country_type', 'rate') %in% names(ch99))) return(tibble::tibble())
    if (has_classifier) ch99$resolution_status <- classify_resolution_status(ch99$ch99_code, ch99$country_type)
    rs <- if ('resolution_status' %in% names(ch99)) ch99$resolution_status else rep(NA_character_, nrow(ch99))
    keep <- !is.na(ch99$rate) & ch99$rate > 0 & grepl('^unresolved', rs %||% '')
    if (!any(keep)) return(tibble::tibble())
    tibble::tibble(
      ch99_code = ch99$ch99_code[keep], authority = (ch99$authority %||% NA_character_)[keep],
      rate = ch99$rate[keep], resolution_status = rs[keep], revision = rev,
      description = substr((ch99$description %||% '')[keep], 1, 120)
    )
  })
  shortlist <- if (nrow(recon) == 0) empty else recon %>%
    dplyr::group_by(ch99_code, resolution_status) %>%
    dplyr::summarise(authority = dplyr::first(authority), max_rate = max(rate),
                     revisions = dplyr::n_distinct(revision),
                     first_revision = min(revision), last_revision = max(revision),
                     description = dplyr::first(description), .groups = 'drop') %>%
    dplyr::arrange(dplyr::desc(max_rate))
  readr::write_csv(shortlist, file.path(output_dir, 'rate_reconciliation_unextracted.csv'))
  message('  [metrics] rate_reconciliation_unextracted.csv: ', nrow(shortlist),
          ' rated-but-unmodeled codes',
          if (nrow(shortlist)) paste0(' (max ', round(max(shortlist$max_rate) * 100), '%)') else '')
  invisible(shortlist)
}

#' Per-revision quality from the PARQUET (arrow pushdown — no monolithic RDS).
emit_revision_quality <- function(output_dir = here::here('output', 'quality'),
                                  parquet_root = here::here('data', 'timeseries', 'rate_timeseries_parquet')) {
  if (!requireNamespace('arrow', quietly = TRUE)) {
    message('  [metrics] arrow unavailable — revision_quality skipped'); return(invisible(NULL))
  }
  parts <- list.files(parquet_root, pattern = '^revision=', full.names = TRUE)
  if (length(parts) == 0) return(invisible(NULL))
  rd <- tryCatch(readr::read_csv(here::here('config', 'revision_dates.csv'), show_col_types = FALSE),
                 error = function(e) NULL)
  rows <- purrr::map_dfr(parts, function(p) {
    ds <- tryCatch(arrow::open_dataset(p), error = function(e) NULL)
    if (is.null(ds)) return(tibble::tibble())
    agg <- tryCatch(
      ds %>% dplyr::summarise(
        n_rows = dplyr::n(), mean_base = mean(base_rate), mean_total = mean(total_rate),
        pct_232 = mean(rate_232 > 0) * 100, pct_301 = mean(rate_301 > 0) * 100,
        pct_ieepa_recip = mean(rate_ieepa_recip > 0) * 100,
        pct_ieepa_fent = mean(rate_ieepa_fent > 0) * 100,
        pct_s122 = mean(rate_s122 > 0) * 100, pct_s201 = mean(rate_section_201 > 0) * 100
      ) %>% dplyr::collect(), error = function(e) NULL)
    if (is.null(agg)) return(tibble::tibble())
    agg$revision <- sub('.*revision=', '', p); agg
  })
  if (nrow(rows) == 0) return(invisible(rows))
  if (!is.null(rd) && 'revision' %in% names(rd)) rows <- dplyr::left_join(rows, rd, by = 'revision')
  if ('effective_date' %in% names(rows)) rows <- dplyr::arrange(rows, effective_date)
  readr::write_csv(rows, file.path(output_dir, 'revision_quality.csv'))
  message('  [metrics] revision_quality.csv: ', nrow(rows), ' revisions (from parquet)')
  invisible(rows)
}

#' Schema check — parquet columns vs the canonical RATE_SCHEMA.
emit_schema_check <- function(output_dir = here::here('output', 'quality'),
                              parquet_root = here::here('data', 'timeseries', 'rate_timeseries_parquet')) {
  if (!requireNamespace('arrow', quietly = TRUE)) return(invisible(NULL))
  parts <- list.files(parquet_root, pattern = '^revision=', full.names = TRUE)
  if (length(parts) == 0) return(invisible(NULL))
  ds <- tryCatch(arrow::open_dataset(parts[length(parts)]), error = function(e) NULL)
  if (is.null(ds)) return(invisible(NULL))
  # `revision` is the Hive partition key (in the dir name, not the file schema)
  # — include it so it isn't a false-positive MISSING.
  present <- union(names(ds), 'revision')
  expected <- if (exists('RATE_SCHEMA')) RATE_SCHEMA else present
  sc <- tibble::tibble(column = union(expected, present)) %>%
    dplyr::mutate(
      in_schema = column %in% expected, in_parquet = column %in% present,
      status = dplyr::case_when(in_schema & in_parquet ~ 'ok',
                                in_schema & !in_parquet ~ 'MISSING',
                                TRUE ~ 'extra'))
  readr::write_csv(sc, file.path(output_dir, 'schema_check.csv'))
  message('  [metrics] schema_check.csv: ', nrow(sc), ' columns (',
          sum(sc$status == 'MISSING'), ' missing, ', sum(sc$status == 'extra'), ' extra)')
  invisible(sc)
}

#' Anomalies — flag large jumps in coverage/mean-rate between adjacent revisions.
emit_anomalies <- function(output_dir = here::here('output', 'quality'), rev_quality = NULL) {
  empty <- tibble::tibble(revision = character(), metric = character(),
                          prev = numeric(), value = numeric(), delta = numeric())
  if (is.null(rev_quality) || nrow(rev_quality) < 2) {
    readr::write_csv(empty, file.path(output_dir, 'anomalies.csv')); return(invisible(empty))
  }
  rq <- if ('effective_date' %in% names(rev_quality)) dplyr::arrange(rev_quality, effective_date) else rev_quality
  out <- list()
  checks <- list(mean_total = 0.05, pct_232 = 15, pct_301 = 15, pct_ieepa_recip = 15)
  for (col in names(checks)) {
    if (!col %in% names(rq)) next
    v <- rq[[col]]; d <- c(NA, diff(v))
    for (i in which(abs(d) > checks[[col]] & !is.na(d))) {
      out[[length(out) + 1]] <- tibble::tibble(revision = rq$revision[i], metric = col,
                                               prev = v[i - 1], value = v[i], delta = d[i])
    }
  }
  res <- if (length(out)) dplyr::bind_rows(out) else empty
  readr::write_csv(res, file.path(output_dir, 'anomalies.csv'))
  message('  [metrics] anomalies.csv: ', nrow(res), ' flagged')
  invisible(res)
}

#' Emit ALL quality/metric artifacts + a freshness manifest. Call at the end of
#' every build, unconditionally. Each artifact is wrapped so one failure cannot
#' abort the build or suppress the others.
emit_quality_metrics <- function(output_dir = here::here('output', 'quality')) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  message('\n--- Quality metrics (auto-regenerated) ---')
  manifest <- list()
  stamp <- function(artifact, df, extra = list()) {
    manifest[[length(manifest) + 1]] <<- tibble::tibble(
      artifact = artifact, rows = nrow(df),
      revisions = if ('revision' %in% names(df)) dplyr::n_distinct(df$revision) else NA_integer_,
      note = if (length(extra)) paste(names(extra), unlist(extra), sep = '=', collapse = '; ') else NA_character_
    )
  }

  triage <- tryCatch(emit_ch99_triage(output_dir),
                     error = function(e) { message('  [metrics] triage failed: ', conditionMessage(e)); tibble::tibble() })
  if (nrow(triage) > 0) {
    stamp('ch99_country_scope_triage.csv', triage,
          list(truly_unresolved = sum(grepl('^unresolved', triage$resolution_status))))

    # Honest per-code unresolved summary (the actionable shortlist).
    unresolved <- triage %>%
      dplyr::filter(grepl('^unresolved', resolution_status)) %>%
      dplyr::group_by(resolution_status, ch99_code) %>%
      dplyr::summarise(authority = dplyr::first(authority),
                       revisions = dplyr::n_distinct(revision),
                       first_revision = min(revision), last_revision = max(revision),
                       description = substr(dplyr::first(description), 1, 160),
                       .groups = 'drop') %>%
      dplyr::arrange(resolution_status, ch99_code)
    readr::write_csv(unresolved, file.path(output_dir, 'ch99_unresolved_summary.csv'))
    stamp('ch99_unresolved_summary.csv', unresolved,
          list(distinct_codes = nrow(unresolved)))
    message('  [metrics] ch99_unresolved_summary.csv: ', nrow(unresolved), ' distinct unresolved codes')
  }

  recon <- tryCatch(emit_rate_reconciliation(output_dir),
                    error = function(e) { message('  [metrics] reconciliation failed: ', conditionMessage(e)); NULL })
  if (!is.null(recon) && nrow(recon) > 0) {
    stamp('rate_reconciliation_unextracted.csv', recon,
          list(max_rate_pct = round(max(recon$max_rate) * 100)))
  }

  # ── Resolution summary — DELIBERATELY non-misleading. Separates codes that
  #    are genuinely handled / not-duty-relevant from the two that actually
  #    matter: rated-but-unmodeled (possible under-collection) and TRULY
  #    unresolved (unknown). "unknown country scope" alone is NOT a problem —
  #    most such entries are resolved by an authority extractor. ──
  if (nrow(triage) > 0) {
    dc <- function(mask) dplyr::n_distinct(triage$ch99_code[mask])
    n_handled <- dc(grepl('^handled_by|^resolved_by', triage$resolution_status))
    n_notduty <- dc(triage$resolution_status %in% c('not_duty_relevant_trq', 'ieepa_exclusion_no_rate'))
    n_unmodeled <- if (!is.null(recon)) nrow(recon) else 0L
    n_truly <- dc(triage$resolution_status == 'unresolved')
    message('  +- Ch99 resolution across ', dplyr::n_distinct(triage$revision),
            ' revisions (distinct codes) ------------------')
    message('  |   handled by an extractor      : ', n_handled, '   (ok)')
    message('  |   not duty-relevant (TRQ/excl) : ', n_notduty, '   (ok)')
    message('  |   rated but NOT yet modeled    : ', n_unmodeled,
            if (n_unmodeled > 0) paste0('   -> rate_reconciliation_unextracted.csv (possible under-collection)') else '   (none)')
    message('  |   TRULY UNRESOLVED             : ', n_truly,
            if (n_truly == 0) '   (none)' else '   <-- needs investigation')
    message('  +-----------------------------------------------------------------')
  }

  sc <- tryCatch(emit_schema_check(output_dir),
                 error = function(e) { message('  [metrics] schema_check failed: ', conditionMessage(e)); NULL })
  if (!is.null(sc)) stamp('schema_check.csv', sc, list(missing = sum(sc$status == 'MISSING')))

  rq <- tryCatch(emit_revision_quality(output_dir),
                 error = function(e) { message('  [metrics] revision_quality failed: ', conditionMessage(e)); NULL })
  if (!is.null(rq) && nrow(rq) > 0) {
    stamp('revision_quality.csv', rq)
    an <- tryCatch(emit_anomalies(output_dir, rq), error = function(e) NULL)
    if (!is.null(an)) stamp('anomalies.csv', an)
  }

  # Freshness manifest — generated_at makes staleness obvious.
  man <- dplyr::bind_rows(manifest)
  if (nrow(man) == 0) man <- tibble::tibble(artifact = character(), rows = integer(),
                                            revisions = integer(), note = character())
  man$generated_at <- as.character(Sys.time())
  readr::write_csv(man, file.path(output_dir, 'metrics_manifest.csv'))
  message('  [metrics] metrics_manifest.csv written (', nrow(man), ' artifacts)')
  invisible(man)
}
