source('src/helpers.R')
source('src/04_parse_products.R')
source('src/05_parse_policy_params.R')
row <- function(code, indent, general = '', special = '', other = '', units = list())
  list(htsno = code, indent = as.character(indent), general = general,
       special = special, other = other, units = units, description = 'Synthetic hierarchy')
fixture <- list(
  row('0101', 0),
  row('0101.21.00', 1, '5%', 'Free (S)', '20%', list('kg', 'No.')),
  row('0101.21.00.10', 2),
  row('0101.29.00', 1),
  row('0101.29.00.10', 2),
  row('0102', 0),
  row('0102.10.00', 1, 'The rate applicable to each garment if separately entered'),
  row('0102.10.00.10', 2))
file <- tempfile(fileext = '.json')
jsonlite::write_json(fixture, file, auto_unbox = TRUE)
products <- parse_products(file)
eligibility <- extract_usmca_eligibility(fixture)
first <- products[products$hts10 == '0101210010', ]
stopifnot(first$base_rate == 0.05, first$rate_column2 == 0.20,
          first$reported_unit_2 == 'No.', first$rate_special == 0)
second <- products[products$hts10 == '0101290010', ]
stopifnot(is.na(second$base_rate), is.na(second$rate_column2),
          is.na(second$rate_special), is.na(second$reported_unit_2) || !nzchar(second$reported_unit_2))
third <- products[products$hts10 == '0102100010', ]
stopifnot(is.na(third$base_rate), grepl('each garment', third$duty_expression_raw))
stopifnot(eligibility$usmca_eligible[eligibility$hts10 == '0101210010'],
          !eligibility$usmca_eligible[eligibility$hts10 == '0101290010'])
unlink(file)
cat('Sibling boundaries, inherited units/preferences and unparsed parents passed\n')
