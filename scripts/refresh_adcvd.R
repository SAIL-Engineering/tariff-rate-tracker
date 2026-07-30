# =============================================================================
# refresh_adcvd.R — keep AD/CVD cash-deposit rates current
# =============================================================================
#
# Administrative reviews reset cash-deposit rates roughly annually PER CASE, so
# a hand-curated rate column is stale by construction. This polls the Federal
# Register from a watermark and appends new per-exporter rates as a time series.
#
# WHAT THIS DOES AND DOES NOT COVER — the distinction is load-bearing:
#
#   RATES        automated. The FR API filtered to the International Trade
#                Administration returns final and amended-final administrative
#                review results with a rigid title grammar and a per-exporter
#                rate table in raw_text. Verified working: 204 notices since
#                2026-05-01.
#
#   ORDER SET    NOT automated. The ITA dataset API requires a subscription key
#                and access.trade.gov/adcvd returns 404, so the universe of
#                active orders cannot currently be seeded from a public
#                endpoint. resources/adcvd_orders.csv is a curated seed and is
#                INCOMPLETE. A rate arriving for an unknown case is reported,
#                never silently dropped, so the gap stays visible.
#
#   SCOPE        never automated, by design. Commerce defines scope in prose and
#                states the HTS numbers are "for convenience only". Whether an
#                article is within scope is a factual determination we do not
#                make; coverage is emitted as a candidate requiring more facts.
#
# Usage:
#   Rscript scripts/refresh_adcvd.R                 # since the watermark
#   Rscript scripts/refresh_adcvd.R --since 2026-01-01
#   Rscript scripts/refresh_adcvd.R --dry-run
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(jsonlite)
})
source(here('src', 'parse_adcvd_notice.R'))

args     <- commandArgs(trailingOnly = TRUE)
dry_run  <- '--dry-run' %in% args
since_i  <- which(args == '--since')
orders_path <- here('resources', 'adcvd_orders.csv')
rates_path  <- here('resources', 'adcvd_rates.csv')
wm_path     <- here('resources', '.adcvd_watermark')

rates  <- suppressMessages(read_csv(rates_path,  show_col_types = FALSE))
orders <- suppressMessages(read_csv(orders_path, show_col_types = FALSE))

since <- if (length(since_i) && length(args) > since_i[1]) {
  as.Date(args[since_i[1] + 1])
} else if (file.exists(wm_path)) {
  as.Date(trimws(readLines(wm_path, warn = FALSE)[1]))
} else {
  max(as.Date(rates$retrieved_date), na.rm = TRUE) - 30
}
message('Polling Federal Register since ', since)

fr_get <- function(params) {
  q <- paste(vapply(names(params), function(k)
    paste0(URLencode(k, TRUE), '=', URLencode(as.character(params[[k]]), TRUE)),
    character(1)), collapse = '&')
  u <- paste0('https://www.federalregister.gov/api/v1/documents.json?', q)
  tryCatch(jsonlite::fromJSON(u, simplifyVector = FALSE), error = function(e) NULL)
}

# The FR API takes repeated keys for array params, which the simple encoder
# above cannot express, so build the URL directly for those.
url <- paste0(
  'https://www.federalregister.gov/api/v1/documents.json',
  '?conditions%5Bagencies%5D%5B%5D=international-trade-administration',
  '&conditions%5Bpublication_date%5D%5Bgte%5D=', format(since),
  '&conditions%5Bterm%5D=', URLencode('final results administrative review', TRUE),
  '&per_page=100&order=oldest',
  '&fields%5B%5D=title&fields%5B%5D=document_number&fields%5B%5D=publication_date',
  '&fields%5B%5D=citation&fields%5B%5D=raw_text_url')

res <- tryCatch(jsonlite::fromJSON(url, simplifyVector = FALSE),
                error = function(e) { message('FR API unreachable: ', conditionMessage(e)); NULL })
if (is.null(res)) quit(status = 1)

docs <- res$results %||% list()
message('Notices returned: ', length(docs), ' (API reports ', res$count %||% 0, ' matching)')

new_rows <- list()
skipped  <- list()

for (d in docs) {
  meta <- parse_adcvd_title(d$title %||% '')
  if (!is_rate_setting_notice(meta$notice_kind)) {
    skipped[[length(skipped) + 1L]] <- tibble(
      document_number = d$document_number %||% NA_character_,
      reason = paste0('not rate-setting (', meta$notice_kind %||% 'unparsed', ')'),
      title = substr(d$title %||% '', 1, 90))
    next
  }
  if (is.null(d$raw_text_url)) next
  txt <- tryCatch(paste(readLines(d$raw_text_url, warn = FALSE), collapse = '\n'),
                  error = function(e) NA_character_)
  tab <- parse_adcvd_rates(txt)
  if (nrow(tab) == 0) {
    skipped[[length(skipped) + 1L]] <- tibble(
      document_number = d$document_number, reason = 'no rate table found',
      title = substr(d$title, 1, 90))
    next
  }
  # Match to a known order by country + product. An unmatched rate is REPORTED,
  # not dropped: the order seed is incomplete and silently discarding rates
  # would hide exactly that.
  cand <- orders %>%
    filter(duty_type == meta$duty_type,
           mapply(function(cn, pr) {
             grepl(cn, meta$country, ignore.case = TRUE) &&
               grepl(substr(pr, 1, 12), meta$product, ignore.case = TRUE)
           }, country, product))
  case <- if (nrow(cand) == 1) cand$case_number[1] else NA_character_
  if (is.na(case)) {
    skipped[[length(skipped) + 1L]] <- tibble(
      document_number = d$document_number,
      reason = sprintf('no matching order for %s / %s (%s) — order seed is incomplete',
                       meta$product %||% '?', meta$country %||% '?', meta$duty_type %||% '?'),
      title = substr(d$title, 1, 90))
    next
  }
  new_rows[[length(new_rows) + 1L]] <- tab %>%
    transmute(case_number = case, exporter, rate, is_all_others,
              effective_from = as.Date(d$publication_date),
              effective_to = NA_character_,
              fr_document_number = d$document_number,
              fr_citation = d$citation %||% NA_character_,
              notice_kind = meta$notice_kind,
              retrieved_date = as.Date(res$results[[1]]$publication_date) )
}

fresh <- if (length(new_rows)) bind_rows(new_rows) else tibble()
skips <- if (length(skipped))  bind_rows(skipped)  else tibble()

message('\nNew rate rows parsed: ', nrow(fresh))
if (nrow(skips) > 0) {
  message('Notices not ingested: ', nrow(skips))
  unmatched <- skips %>% filter(grepl('no matching order', reason))
  if (nrow(unmatched) > 0) {
    message('  ', nrow(unmatched), ' carried rates for orders NOT in the seed:')
    for (i in seq_len(min(8, nrow(unmatched)))) message('    - ', unmatched$title[i])
    message('  Add these to resources/adcvd_orders.csv — their rates are being lost.')
  }
}

if (dry_run) { message('\n--dry-run: nothing written'); quit(status = 0) }

if (nrow(fresh) > 0) {
  # Supersede: an earlier open-ended rate for the same case+exporter closes the
  # day before the new one starts, so the series never has two live rates.
  combined <- bind_rows(rates %>% mutate(effective_from = as.Date(effective_from)), fresh) %>%
    arrange(case_number, exporter, effective_from) %>%
    group_by(case_number, exporter) %>%
    mutate(effective_to = if_else(row_number() < n(),
                                  as.character(lead(effective_from) - 1),
                                  as.character(effective_to))) %>%
    ungroup()
  write_csv(combined, rates_path)
  message('Wrote ', rates_path, ' (', nrow(combined), ' rows)')
}
writeLines(format(Sys.Date()), wm_path)
message('Watermark: ', format(Sys.Date()))
