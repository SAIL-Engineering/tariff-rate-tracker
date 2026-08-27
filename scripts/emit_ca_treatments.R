#!/usr/bin/env Rscript
# emit_ca_treatments.R — regenerate config/ca_tariff_treatments.json from the
# hand-reviewed YAML. The YAML is the single source of truth (same pattern as
# config/duty_citations.yaml -> emit_duty_citations); the JSON is the committed
# artifact build_duty_rates.py reads (Python side stays dependency-free).
#
#   Rscript scripts/emit_ca_treatments.R
suppressMessages({library(yaml); library(jsonlite)})
src <- "config/ca_tariff_treatments.yaml"
dst <- "config/ca_tariff_treatments.json"
t <- yaml::read_yaml(src)
stopifnot(!is.null(t$treatments), length(t$treatments) >= 25)
# YAML gotcha this file has already hit once: an unquoted NO parses as FALSE.
stopifnot(identical(t$treatments$NT$origin_countries, "NO"))
jsonlite::write_json(t, dst, auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("wrote %s (%d treatments)\n", dst, length(t$treatments)))
