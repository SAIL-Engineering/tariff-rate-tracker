source('src/shipment_duty_expression.R')
source('src/resolve_shipment_duties.R')
template <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json', simplifyVector = FALSE)[[1]]
check <- function(text, facts, expected = NULL, status = 'complete') {
  parsed <- parse_shipment_duty_expression(text)
  stopifnot(parsed$status == 'parsed')
  bundle <- template$bundle
  bundle$rules <- bundle$rules[1]
  bundle$coverage[[1]]$rule_ids <- list(bundle$rules[[1]]$id)
  bundle$rules[[1]]$formula <- parsed$formula
  bundle$rules[[1]]$input_constraints <- parsed$input_constraints
  bundle$fact_definitions <- parsed$fact_definitions
  result <- evaluate_shipment_bundle(bundle, template$hts10, template$country, template$entry_at, facts)
  stopifnot(result$status == status)
  if (!is.null(expected)) stopifnot(abs(result$complete_total - expected) < 1e-9)
  invisible(result)
}
check('Free', list(), 0)
check('<i>Free</i>', list(), 0)
check('6.5¢/gross<il></il>', list(quantity_gross = 1), .065)
check('6.5&cent;/gross', list(quantity_gross = 1), .065)
check('&#36;2/kg&nbsp;+ 5%', list(customs_value = 100, quantity_kg = 2), 9)
p <- parse_shipment_duty_expression('6.5¢/gross<il></il>')
stopifnot(p$raw == '6.5¢/gross<il></il>', p$normalized_text == '6.5¢/gross',
          'presentation_markup' %in% unlist(p$normalization_steps))
check('6.8%', list(customs_value = 1000), 68)
stopifnot(check('13.7%',list(customs_value=500),68.5)$complete_total==68.5)
stopifnot(check('0.07%',list(customs_value=1000),.7)$complete_total==.7)
stopifnot(check('13.7¢/kg',list(quantity_kg=500),68.5)$complete_total==68.5)
check('4.4¢/kg', list(quantity_kg = 100), 4.4)
check('$1.104/kg + 14.9%', list(customs_value = 1000, quantity_kg = 100), 259.4)
check('10¢ each + 2.5%', list(customs_value = 1000, quantity_each = 20), 27)
check('$1.50/doz', list(quantity_doz = 3), 4.5)
check('10% but not less than $2/kg', list(customs_value = 1000, quantity_kg = 100), 200)
check('$2/kg but not more than 10%', list(customs_value = 1000, quantity_kg = 100), 100)
check('5.7¢/kg on drained weight + 8%',
      list(customs_value = 1000, quantity_kg_on_drained_weight = 50), 82.85)
check('51¢ each + 6.25% on the case and strap, band or bracelet + 5.3% on the battery',
      list(customs_value = 1000, quantity_each = 10,
           value_case_and_strap_band_or_bracelet = 100, value_battery = 20), 12.41)
r <- check('4.4¢/kg', list(customs_value = 1000, quantity = 100), status = 'needs_inputs')
stopifnot(identical(r$missing_inputs, 'quantity_kg'), is.null(r$complete_total))
for (text in c('', '4.4/kg', '4.4¢/kg + unspecified', '5% on an unknown basis',
               'The rate applicable to each garment if separately entered',
               'See note 2', '10% less 2%', 'Free under quota', '1.2.3%',
               '<i>Free under quota</i>', '<duty rate="25">Free</duty>',
               '<i data-condition="quota">Free</i>', '5% &unknown;')) {
  p <- parse_shipment_duty_expression(text)
  stopifnot(p$status == 'unresolved_source', is.null(p$formula))
}
cat('Complete duty expressions, exact quantity units, compound sums and bounds passed\n')

# The schedule prints one legal unit two ways. Both share a fact key, because
# the key collapses punctuation, so both must also carry one unit string: two
# spellings under one key read as a conflicting definition to the valuation
# checks in section232_autos.py and section301_labor_pricing.py, and cost
# 2025_basic and 2026_rev_22 their whole revision.
spaced <- parse_shipment_duty_expression('2.1¢/pf. liter')$fact_definitions
tight <- parse_shipment_duty_expression('2.1¢/pf.liter')$fact_definitions
stopifnot('quantity_pf_liter' %in% names(spaced),
          'quantity_pf_liter' %in% names(tight),
          identical(spaced$quantity_pf_liter$unit, 'pf.liter'),
          identical(spaced$quantity_pf_liter, tight$quantity_pf_liter))
check('2.1¢/pf. liter', list(quantity_pf_liter = 10), .21)
check('2.1¢/pf.liter', list(quantity_pf_liter = 10), .21)
# A space that carries meaning is still kept.
units <- parse_shipment_duty_expression('1.4¢/clean kg')$fact_definitions
stopifnot(identical(units$quantity_clean_kg$unit, 'clean kg'))
cat('One legal unit yields one fact definition whichever way the schedule prints it\n')
