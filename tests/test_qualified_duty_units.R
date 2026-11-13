# =============================================================================
# Tests for the per-unit General-rate parse (parse_rate_extended(qualified_units
# = TRUE) in src/helpers.R) and its agreement with the shipment parser
# (parse_shipment_duty_expression in src/shipment_duty_expression.R).
#
# A per-unit base duty has no ad valorem form, so specific_amount and its unit
# are the only way a reader can price it. 252 lines of every 2025/2026 revision
# had a per-unit General rate the plain parse could not read ("0.9¢ each",
# "8.6¢/kg on drained weight"); this parse reads every one that needs a single
# quantity, and leaves the rest unread on purpose.
#
# Run: Rscript tests/test_qualified_duty_units.R
# =============================================================================

suppressMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'helpers.R'))
source(here('src', 'shipment_duty_expression.R'))

pass_count <- 0; fail_count <- 0
run_test <- function(name, expr) {
  tryCatch({ force(expr); message('  PASS: ', name); pass_count <<- pass_count + 1 },
           error = function(e) { message('  FAIL: ', name, ' — ', conditionMessage(e))
                                 fail_count <<- fail_count + 1 })
}

q <- function(x) parse_rate_extended(x, qualified_units = TRUE)

expect_rate <- function(x, type, amount, unit, av = NA_real_) {
  r <- q(x)
  if (!identical(r$type, type)) stop(x, ': type ', r$type, ', expected ', type)
  if (!isTRUE(all.equal(r$specific_amount, amount)))
    stop(x, ': amount ', r$specific_amount, ', expected ', amount)
  if (!identical(r$specific_rate_unit, unit))
    stop(x, ': unit "', r$specific_rate_unit, '", expected "', unit, '"')
  if (!isTRUE(all.equal(r$ad_valorem_pct, av)))
    stop(x, ': ad valorem ', r$ad_valorem_pct, ', expected ', av)
  if (!identical(r$raw, x)) stop(x, ': raw text not kept')
}

message('\n=== Rates this parse reads ===')

run_test('a per-article amount reads as "each"', {
  expect_rate('0.9¢ each', 'specific', 0.009, 'each')
  expect_rate('$1.44 each', 'specific', 1.44, 'each')
})

run_test('the measurement qualifier stays on the unit', {
  # Charged on the weight without the liquid, the kilograms of lead in the
  # article, and so on. Reduced to "kg", the article's own weight would be
  # entered and the duty overstated.
  expect_rate('8.6¢/kg on drained weight', 'specific', 0.086, 'kg on drained weight')
  expect_rate('1.7¢/kg on lead content', 'specific', 0.017, 'kg on lead content')
  expect_rate('3.6606¢/kg of total sugars', 'specific', 0.036606, 'kg of total sugars')
  expect_rate('5¢/kg on contents and container', 'specific', 0.05, 'kg on contents and container')
  expect_rate('1.5¢/kg on entire contents of container', 'specific', 0.015,
              'kg on entire contents of container')
  expect_rate('18.7¢/clean kg', 'specific', 0.187, 'clean kg')
})

run_test('a compound rate keeps both parts, in either order and spacing', {
  expect_rate('0.4¢ each + 2.7%', 'compound', 0.004, 'each', 0.027)
  expect_rate('5.7¢/kg on drained weight +8%', 'compound', 0.057, 'kg on drained weight', 0.08)
  expect_rate('12.8¢/kg on molybdenum content + 1.8%', 'compound', 0.128,
              'kg on molybdenum content', 0.018)
  expect_rate('16.9¢/kg of total sugars + 5.1%', 'compound', 0.169, 'kg of total sugars', 0.051)
  expect_rate('10¢/1,000 pins + 3.5%', 'compound', 0.10, '1,000 pins', 0.035)
  expect_rate('5% + 1¢/kg', 'compound', 0.01, 'kg', 0.05)
})

run_test('schedule markup and spacing slips are read through', {
  expect_rate('$1.13/m<sup>3</sup>', 'specific', 1.13, 'm3')
  expect_rate('14.5¢/m<sup>2 </sup>+ 0.4%', 'compound', 0.145, 'm2', 0.004)
  expect_rate('6.5¢/gross<il></il>', 'specific', 0.065, 'gross')
  expect_rate('4.5¢/ liter', 'specific', 0.045, 'liter')
  expect_rate('3¢/pf. liter', 'specific', 0.03, 'pf.liter')
})

run_test('the rounding rule follows the read amount (19 CFR 159.3)', {
  stopifnot(determine_rounding_rule(q('$1.44 each')) == '19cfr159.3_specific_gt1',
            determine_rounding_rule(q('0.9¢ each')) == '19cfr159.3_specific_lte1',
            determine_rounding_rule(q('0.4¢ each + 2.7%')) == '19cfr159.3_compound_lte1')
})

message('\n=== Rates it leaves unread ===')

run_test('a rate needing more than one quantity, a scale or a cap stays unread', {
  for (x in c('36¢ each + 5.6% + 2¢/jewel',
              '0.7¢/kg on copper content + 0.7¢/kg on lead content',
              '4.4¢/liter + 31.4¢/pf. liter',
              '13.5¢/kg + 6.3% + 1.9¢/article',
              '0.18¢/line/ gross + 2.5%',
              paste('3.6606¢/kg less 0.020668¢/kg for each degree under 100 degrees',
                    '(and fractions of a degree in proportion) but not less than 3.143854¢/kg'),
              '4.3% + 1.7¢/jewel + 0.2¢ for each other piece or part, but if consisting in part of a plate or a set of plates the total duty shall not exceed the duty for the complete movement',
              '3.1¢/liter + 22.1¢/pf. liter on ethyl alcohol content',
              '45%',
              '5% + 6%',
              '5 each')) {
    r <- q(x)
    if (!is.na(r$specific_amount)) stop(x, ': read as ', r$specific_amount, ' ', r$specific_rate_unit)
  }
})

run_test('Column 2 and special-program callers keep the plain parse', {
  # Only the General column asks for qualified units, so Column 2 and special
  # rates emit what they did before.
  stopifnot(identical(parse_rate_extended('0.9¢ each')$type, 'unknown'),
            is.na(parse_rate_extended('8.6¢/kg on drained weight')$specific_amount))
})

run_test('rates the plain parse already read come out the same', {
  for (x in c('1¢/kg', '$1.104/kg + 14.9%', '46.3¢/kg + 14.9%', '6.8%', 'Free',
              '2.1¢/pf.liter', '$3/head', '')) {
    if (!identical(q(x), parse_rate_extended(x))) stop(x, ': qualified parse differs')
  }
})

message('\n=== Agreement with the shipment parser ===')

# Every per-unit General text in the 2019-2026 product data (456 strings).
fixture <- read.csv(here('tests', 'fixtures', 'general_rate_quantity_strings.csv'),
                    encoding = 'UTF-8', stringsAsFactors = FALSE)$text

# The shipment parser's formula as a list of terms: per-unit (unit + USD
# amount), percent of customs value, or anything else.
amount_of <- function(node) {
  if (!is.null(node$value)) return(node$value)
  if (identical(node$op, 'divide')) return(amount_of(node$args[[1]]) / amount_of(node$args[[2]]))
  NA_real_
}
terms_of <- function(node, defs) {
  if (!is.null(node$value)) return(list())
  if (identical(node$op, 'add')) return(do.call(c, lapply(node$args, terms_of, defs)))
  if (identical(node$op, 'multiply') && !is.null(node$args[[1]]$fact)) {
    key <- node$args[[1]]$fact
    if (startsWith(key, 'quantity_'))
      return(list(list(kind = 'quantity', unit = defs[[key]]$unit, amount = amount_of(node$args[[2]]))))
    if (key == 'customs_value') return(list(list(kind = 'percent', amount = amount_of(node$args[[2]]))))
  }
  list(list(kind = 'other'))
}
single_quantity <- function(text) {
  s <- parse_shipment_duty_expression(text)
  if (s$status != 'parsed') return(NULL)
  t <- terms_of(s$formula, s$fact_definitions)
  kinds <- vapply(t, `[[`, character(1), 'kind')
  if (sum(kinds == 'quantity') != 1 || any(kinds == 'other') || sum(kinds == 'percent') > 1) return(NULL)
  t[[which(kinds == 'quantity')]]
}

# Read here but not by the shipment parser: its pattern needs the unit right
# after the slash. Same unit, so the rate row is not wrong; the shipment path
# reports the line unresolved until its parser takes the space too.
SHIPMENT_PARSER_GAPS <- c('4.5¢/ liter')

run_test('both parsers name the same unit and amount', {
  bad <- character()
  for (x in fixture) {
    r <- q(x)
    s <- single_quantity(x)
    if (!is.na(r$specific_amount)) {
      if (is.null(s)) {
        if (!x %in% SHIPMENT_PARSER_GAPS) bad <- c(bad, paste0(x, ' (shipment parser: not a single quantity)'))
      } else if (!identical(s$unit, r$specific_rate_unit) ||
                 !isTRUE(all.equal(s$amount, r$specific_amount))) {
        bad <- c(bad, sprintf('%s (%s %s vs shipment %s %s)', x, r$specific_amount,
                              r$specific_rate_unit, s$amount, s$unit))
      }
    } else if (!is.null(s)) {
      bad <- c(bad, paste0(x, ' (shipment parser reads one quantity; this parse reads none)'))
    }
  }
  if (length(bad)) stop(length(bad), ' disagreement(s):\n    ', paste(bad, collapse = '\n    '))
})

run_test('the gap list names only texts the shipment parser still misses', {
  for (x in SHIPMENT_PARSER_GAPS) {
    if (!is.null(single_quantity(x))) stop(x, ' is read by the shipment parser now; drop it from the list')
  }
})

message(sprintf('\n%d passed, %d failed', pass_count, fail_count))
if (fail_count > 0) quit(status = 1)
