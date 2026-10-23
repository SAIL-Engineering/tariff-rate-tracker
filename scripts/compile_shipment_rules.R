# A local composition step, not a timeseries build or database publication.
# Rscript scripts/compile_shipment_rules.R BASE_BUNDLE OUTPUT_BUNDLE FRAGMENT...
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) stop('Usage: BASE_BUNDLE OUTPUT_BUNDLE FRAGMENT...')
if (file.exists(args[2])) stop('Output exists; use a new versioned path')
source('src/compile_shipment_rules.R')
bundle <- jsonlite::fromJSON(args[1], simplifyVector = FALSE)
fragments <- lapply(args[-c(1, 2)], read_shipment_rule_fragment)
result <- compose_shipment_rules(bundle, fragments)
jsonlite::write_json(result, args[2], auto_unbox = TRUE, pretty = TRUE, null = 'null', digits = NA)
cat('Wrote composed rules; coverage is not automatically verified:', args[2], '\n')
