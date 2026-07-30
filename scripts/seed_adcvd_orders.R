# =============================================================================
# seed_adcvd_orders.R — populate the AD/CVD order universe
# =============================================================================
#
# resources/adcvd_orders.csv ships with a 4-order seed, which is a placeholder:
# hundreds of orders are active, and scripts/refresh_adcvd.R reports ~30 notices
# a month carrying rates for orders it cannot match. This fills that gap.
#
# ITA dataset ITA-0039 "Products Subject to Antidumping and Countervailing Duty
# Orders" is the authoritative list. It is published in several places and this
# script TRIES EACH IN TURN, reporting which one answered — the endpoints move,
# and a script that fails without saying which source was unreachable is
# useless for diagnosing it.
#
#   1. api.trade.gov/data/id/ITA-0039        documented, described as public
#   2. ita.data.commerce.gov (Socrata)       mirror, usually open, supports
#                                            $limit/$offset paging
#   3. catalog.data.gov package_search       resolves current distribution URLs
#                                            when the direct endpoints move
#
# If ITA_API_KEY is set it is sent as `subscription-key`. Whether a key is
# actually required has NOT been confirmed — the direct endpoints are
# unreachable from the development sandbox (selective egress; DNS resolves, the
# connection does not complete), so run this from a normal network first and
# only pursue a key if it returns 401/403.
#
# Usage:
#   Rscript scripts/seed_adcvd_orders.R              # probe + write
#   Rscript scripts/seed_adcvd_orders.R --dry-run    # probe only
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(jsonlite)
})

args    <- commandArgs(trailingOnly = TRUE)
dry_run <- '--dry-run' %in% args
api_key <- Sys.getenv('ITA_API_KEY')
out_path <- here('resources', 'adcvd_orders.csv')

hdr <- if (nzchar(api_key)) c('subscription-key' = api_key) else character(0)

try_fetch <- function(label, url, parse) {
  message('\n[', label, ']\n  ', url)
  res <- tryCatch({
    con <- if (length(hdr)) {
      curl::curl(url, handle = curl::new_handle(.list = list()) |>
                   curl::handle_setheaders(.list = as.list(hdr)))
    } else url
    txt <- paste(readLines(con, warn = FALSE), collapse = '\n')
    parse(txt)
  }, error = function(e) { message('  UNREACHABLE: ', conditionMessage(e)); NULL })
  if (is.null(res) || nrow(res) == 0) { message('  no rows'); return(NULL) }
  message('  OK — ', nrow(res), ' rows')
  res
}

# --- normalise whatever shape arrives into our schema -------------------------
to_orders <- function(df) {
  nm <- tolower(names(df))
  pick <- function(...) {
    for (cand in c(...)) { i <- which(nm == cand); if (length(i)) return(df[[i[1]]]) }
    rep(NA_character_, nrow(df))
  }
  tibble(
    case_number = as.character(pick('case_number', 'case_no', 'caseno', 'case')),
    duty_type   = toupper(as.character(pick('duty_type', 'type', 'proceeding_type'))),
    country     = as.character(pick('country', 'country_name')),
    country_census = NA_character_,
    product     = as.character(pick('product', 'product_name', 'commodity', 'short_name')),
    hts_prefixes = as.character(pick('hts', 'hts_numbers', 'htsus', 'tariff_numbers')),
    scope_note  = as.character(pick('scope', 'scope_description', 'description')),
    order_date  = as.character(pick('order_date', 'published_date', 'effective_date')),
    revoked_date = as.character(pick('revoked_date', 'revocation_date')),
    status      = as.character(pick('status', 'case_status')),
    citation_key = NA_character_,
    source_note = 'ITA-0039'
  ) %>%
    filter(!is.na(case_number), nzchar(case_number)) %>%
    mutate(duty_type = case_when(
      grepl('^A', case_number) | grepl('ANTIDUMP', duty_type) ~ 'AD',
      grepl('^C', case_number) | grepl('COUNTERVAIL', duty_type) ~ 'CVD',
      TRUE ~ duty_type)) %>%
    distinct(case_number, .keep_all = TRUE)
}

orders <- NULL

orders <- orders %||% try_fetch(
  'api.trade.gov ITA-0039', 'https://api.trade.gov/data/id/ITA-0039',
  function(txt) {
    j <- jsonlite::fromJSON(txt, flatten = TRUE)
    d <- if (is.data.frame(j)) j else j$results %||% j$data %||% NULL
    if (is.null(d)) return(tibble()) else to_orders(as_tibble(d))
  })

# The Socrata instance at ita.data.commerce.gov does NOT carry ITA-0039. Its
# catalog holds only AD/CVD performance-metric datasets (thc2-npf4, sxss-zpt3,
# 6duv-xvek, pyp5-rsmn) and its /api/catalog/v1 is a FEDERATED search that
# returns other domains' datasets, so a hit there is not evidence of an ITA
# mirror. Checked 2026-07-30; left here as a negative result rather than
# silently dropped, so the next person does not re-derive it.
orders <- orders %||% try_fetch(
  'Commerce Data Hub direct download',
  'https://data.commerce.gov/api/views/ITA-0039/rows.json?accessType=DOWNLOAD',
  function(txt) {
    j <- jsonlite::fromJSON(txt, flatten = TRUE)
    d <- j$data %||% NULL
    if (is.null(d)) return(tibble())
    cols <- vapply(j$meta$view$columns, function(c) c$fieldName %||% '', character(1))
    df <- as_tibble(as.data.frame(d, stringsAsFactors = FALSE))
    if (ncol(df) == length(cols)) names(df) <- cols
    to_orders(df)
  })

orders <- orders %||% try_fetch(
  'catalog.data.gov (resolve distributions)',
  paste0('https://catalog.data.gov/api/3/action/package_search?rows=3&q=',
         URLencode('Products Subject to Antidumping and Countervailing Duty Orders', TRUE)),
  function(txt) {
    j <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
    rs <- j$result$results %||% list()
    urls <- unlist(lapply(rs, function(r) vapply(r$resources %||% list(),
                                                 function(x) x$url %||% '', character(1))))
    urls <- urls[grepl('\\.(json|csv)$', urls, ignore.case = TRUE)]
    message('  candidate distributions: ', length(urls))
    for (u in head(urls, 4)) message('    ', u)
    tibble()   # report only; the URLs are for the operator to try directly
  })

if (is.null(orders)) {
  message('\n', strrep('!', 70))
  message('NO SOURCE ANSWERED — the order seed is unchanged and still incomplete.')
  message('Run this from a normal network. If a source returns 401/403 then a')
  message('key IS required; register at the ITA developer portal or contact the')
  message('dataset owner (Brooke.Kennedy@trade.gov) and set ITA_API_KEY.')
  message('Until then scripts/refresh_adcvd.R keeps NAMING the unmatched orders')
  message('rather than dropping them, so nothing is lost silently.')
  message(strrep('!', 70))
  quit(status = 1)
}

message('\nParsed ', nrow(orders), ' orders (AD: ', sum(orders$duty_type == 'AD', na.rm = TRUE),
        ', CVD: ', sum(orders$duty_type == 'CVD', na.rm = TRUE), ')')

if (dry_run) { message('--dry-run: nothing written'); quit(status = 0) }

# Preserve any hand-curated rows that the feed does not carry.
existing <- suppressMessages(readr::read_csv(out_path, show_col_types = FALSE))
merged <- bind_rows(orders, existing %>% filter(!case_number %in% orders$case_number)) %>%
  arrange(case_number)
readr::write_csv(merged, out_path)
message('Wrote ', out_path, ' (', nrow(merged), ' orders; ',
        nrow(merged) - nrow(orders), ' hand-curated rows preserved)')
