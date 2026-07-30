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
page_url <- function(pg) paste0(
  'https://www.federalregister.gov/api/v1/documents.json',
  '?conditions%5Bagencies%5D%5B%5D=international-trade-administration',
  '&conditions%5Bpublication_date%5D%5Bgte%5D=', format(since),
  '&conditions%5Bterm%5D=', URLencode('final results administrative review', TRUE),
  '&per_page=100&order=oldest&page=', pg,
  '&fields%5B%5D=title&fields%5B%5D=document_number&fields%5B%5D=publication_date',
  '&fields%5B%5D=citation&fields%5B%5D=raw_text_url')

res <- tryCatch(jsonlite::fromJSON(page_url(1), simplifyVector = FALSE),
                error = function(e) { message('FR API unreachable: ', conditionMessage(e)); NULL })
if (is.null(res)) quit(status = 1)

total <- res$count %||% 0
docs  <- res$results %||% list()

# The API caps a page at 100. Without paging the order bootstrap silently
# converges on whatever the first page happened to contain — 100 of 480 in a
# six-month window — and the resulting coverage would look complete while
# missing most of it.
n_pages <- min(ceiling(total / 100), 20)   # 20 pages = 2,000 notices; hard stop
if (n_pages > 1) {
  for (pg in 2:n_pages) {
    r <- tryCatch(jsonlite::fromJSON(page_url(pg), simplifyVector = FALSE),
                  error = function(e) NULL)
    if (is.null(r) || length(r$results %||% list()) == 0) break
    docs <- c(docs, r$results)
  }
}
message('Notices retrieved: ', length(docs), ' of ', total, ' matching',
        if (total > length(docs)) paste0('  [CAPPED at ', n_pages, ' pages]') else '')

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

# --- bootstrap the order universe from the notices themselves -----------------
# The ITA feed for the order list is not reachable (api.trade.gov does not
# complete TLS, and the "data visualization" is a Power BI report, not a feed),
# so the universe cannot be seeded top-down without a developer-portal key.
#
# It does not have to be. Every administrative-review notice NAMES its product,
# country and duty type — that is what the title grammar gives us. The orders
# under active review are exactly the ones whose rates change, so accumulating
# them from the notice stream converges on the set that actually matters, with
# no key and no scraping.
#
# These are written as CANDIDATES, not merged into adcvd_orders.csv. The case
# number is not in the title and has to be attached by a human from the notice
# body, and scope is narrative — so promotion stays a reviewed step.
if (nrow(skips) > 0) {
  cand <- skips %>% filter(grepl('no matching order', reason))
  if (nrow(cand) > 0) {
    parsed <- map_dfr(cand$title, function(t) {
      m <- parse_adcvd_title(t)
      tibble(product = m$product %||% NA_character_,
             country = m$country %||% NA_character_,
             duty_type = m$duty_type %||% NA_character_)
    }) %>%
      filter(!is.na(product), !is.na(country)) %>%
      distinct(product, country, duty_type) %>%
      mutate(case_number = NA_character_, status = 'candidate',
             source_note = 'observed in an administrative-review notice',
             first_seen = format(Sys.Date()))

    cand_path <- here('resources', 'adcvd_orders.candidates.csv')
    prior <- if (file.exists(cand_path)) {
      suppressMessages(read_csv(cand_path, show_col_types = FALSE))
    } else parsed[0, ]
    merged_cand <- bind_rows(prior, parsed) %>%
      distinct(product, country, duty_type, .keep_all = TRUE) %>%
      arrange(country, product)
    if (!dry_run) {
      write_csv(merged_cand, cand_path)
      message('  wrote ', nrow(merged_cand), ' candidate order(s) to ',
              basename(cand_path), ' (+', nrow(merged_cand) - nrow(prior), ' new)')
    } else {
      message('  would record ', nrow(parsed), ' candidate order(s) (dry-run)')
    }
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
