# =============================================================================
# test_adcvd_notice.R — Phase 6: parsing Commerce AD/CVD notices
# =============================================================================
# Run: Rscript tests/test_adcvd_notice.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'parse_adcvd_notice.R'))

.pass <- 0L; .fail <- 0L
run_test <- function(desc, expr) {
  ok <- tryCatch({ force(expr); TRUE }, error = function(e) {
    message('  FAIL: ', desc, ' — ', conditionMessage(e)); FALSE })
  if (ok) { message('  PASS: ', desc); .pass <<- .pass + 1L } else .fail <<- .fail + 1L
}

message('\n--- Notice title grammar ---')

run_test('final and amended-final results parse into product/country/type', {
  a <- parse_adcvd_title('Certain Aluminum Foil From the People’s Republic of China: Amended Final Results of Antidumping Duty Administrative Review; 2023-2024')
  stopifnot(identical(a$duty_type, 'AD'))
  stopifnot(identical(a$notice_kind, 'amended_final'))
  stopifnot(identical(a$product, 'Certain Aluminum Foil'))
  stopifnot(grepl('China', a$country))
  stopifnot(identical(a$period, '2023-2024'))

  b <- parse_adcvd_title('Certain Corrosion-Resistant Steel Products From Korea: Final Results of Countervailing Duty Administrative Review; 2022-2023')
  stopifnot(identical(b$duty_type, 'CVD'), identical(b$notice_kind, 'final'))
  stopifnot(identical(b$country, 'Korea'))
})

run_test('initiation notices are identified and never treated as rate-setting', {
  # These announce reviews, carry no rate table, and would otherwise be mined
  # for numbers that do not exist.
  i <- parse_adcvd_title('Initiation of Antidumping and Countervailing Duty Administrative Reviews')
  stopifnot(identical(i$notice_kind, 'initiation'))
  stopifnot(!is_rate_setting_notice(i$notice_kind))
})

run_test('preliminary results do not set the operative rate', {
  p <- parse_adcvd_title('Widgets From Canada: Preliminary Results of Antidumping Duty Administrative Review; 2024-2025')
  stopifnot(identical(p$notice_kind, 'preliminary'))
  stopifnot(!is_rate_setting_notice(p$notice_kind))
  stopifnot(is_rate_setting_notice('final'), is_rate_setting_notice('amended_final'))
})

run_test('order-lifecycle notices are distinguished from review results', {
  # These define the order UNIVERSE and carry no "Results of" clause. Active
  # set = established + continued - revoked, all derivable from the Federal
  # Register — which matters because the ITA dataset API is unreachable and the
  # ADCVD search app is a Blazor server app with no public JSON endpoint.
  o <- parse_adcvd_title('Paper File Folders From Sri Lanka: Antidumping Duty Order')
  stopifnot(identical(o$notice_kind, 'order'), identical(o$duty_type, 'AD'))
  stopifnot(identical(o$country, 'Sri Lanka'))

  cvd <- parse_adcvd_title('Steel Concrete Reinforcing Bar From Algeria: Countervailing Duty Order')
  stopifnot(identical(cvd$notice_kind, 'order'), identical(cvd$duty_type, 'CVD'))

  cont <- parse_adcvd_title('Stainless Steel Bar From India: Continuation of Antidumping Duty Order')
  stopifnot(identical(cont$notice_kind, 'continuation'))

  rev <- parse_adcvd_title('Certain Aluminum Foil From China: Revocation of Antidumping Duty Order')
  stopifnot(identical(rev$notice_kind, 'revocation'))

  # None of them set cash-deposit rates — only review results do.
  for (k in c('order', 'continuation', 'revocation')) {
    stopifnot(!is_rate_setting_notice(k))
  }
})

run_test('a non-matching title yields NA rather than a guess', {
  n <- parse_adcvd_title('Notice of Scheduling of Hearing')
  stopifnot(is.na(n$duty_type), is.na(n$product), is.na(n$country))
})

message('\n--- Per-exporter rate tables ---')

run_test('a real multi-exporter table parses with distinct firm rates', {
  # Verbatim layout from 91 FR (doc 2026-10525), aluminum foil.
  txt <- paste(
    'Producer/Exporter                                    Weighted-average dumping margin (percent)',
    'Jiangsu Dingsheng New Materials Joint-Stock            26.60',
    'Jiangsu Zhongji Lamination Materials Co., Ltd./        29.89',
    'Dong-IL Aluminium Co., Ltd                             28.01',
    sep = '\n')
  r <- parse_adcvd_rates(txt)
  stopifnot(nrow(r) == 3)
  stopifnot(abs(r$rate[1] - 0.2660) < 1e-12)   # percent -> decimal
  stopifnot(abs(r$rate[2] - 0.2989) < 1e-12)
  stopifnot(!any(r$is_all_others))
})

run_test('the residual rate is identified under its several names', {
  # 'ALL COMPANIES' came from real cached Avalara data — 8483308040/CN and
  # 8483908080/CN both carry an ADD of 93% under that name. Missing it would
  # file the residual rate as one firm's specific margin.
  for (nm in c('All Others', 'Review-Specific Rate for Non-Examined Companies',
               'China-Wide Entity', 'ALL COMPANIES', 'All Companies')) {
    r <- parse_adcvd_rates(paste0(nm, '        17.76'))
    stopifnot(nrow(r) == 1)
    if (!r$is_all_others[1]) stop('not flagged as residual: ', nm)
  }
})

run_test('footnote markers and FR entity escapes are stripped from firm names', {
  r <- parse_adcvd_rates('Asociaci[oacute]n de Cooperativas Argentinas C.L \\10\\   17.76')
  stopifnot(nrow(r) == 1)
  stopifnot(!grepl('\\[|\\\\', r$exporter[1]))
})

run_test('table furniture and stray numbers are not read as exporters', {
  txt <- paste('Period of Review                       2023-2024',
               'Total                                    100.00',
               'Real Company Ltd                          12.34', sep = '\n')
  r <- parse_adcvd_rates(txt)
  stopifnot(nrow(r) == 1, identical(r$exporter[1], 'Real Company Ltd'))
})

run_test('a notice with no rate table yields no rows, not a fabricated one', {
  # Corrections and procedural notices carry no margins. Inventing a rate here
  # would be worse than reporting none — AD/CVD routinely exceeds 200%.
  stopifnot(nrow(parse_adcvd_rates('This document corrects a typographical error.')) == 0)
  stopifnot(nrow(parse_adcvd_rates('')) == 0)
  stopifnot(nrow(parse_adcvd_rates(NA_character_)) == 0)
})

run_test('rates are returned as decimals, never as percents', {
  r <- parse_adcvd_rates('Some Exporter Co        221.00')
  stopifnot(abs(r$rate[1] - 2.21) < 1e-12)   # 221% -> 2.21, not 221
})

message('\n', strrep('=', 50))
message('Tests: ', .pass, ' passed, ', .fail, ' failed')
message(strrep('=', 50))
if (.fail > 0) quit(status = 1)
