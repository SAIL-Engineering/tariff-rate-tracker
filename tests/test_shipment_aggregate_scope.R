suppressPackageStartupMessages({library(tidyverse);library(here)})
source(here('src','helpers.R'));source(here('src','shipment_build.R'))
# Two kinds of "no shipment projection" that must not be conflated. A build that
# asked for a shipment contract and did not get one has no source-backed value,
# so statutory_* must not imply one. A build run with SAIL_EMIT_NORMALIZED=0
# never asked: it is the aggregate-history writer, and the aggregate pipeline
# computed those numbers itself. Blanking them there is destructive against what
# production already serves, and SAIL validates eight statutory fields with
# isNumber rather than a nullable check, so NULLs coerce to zero in its
# arithmetic rather than reading as absent.
rates <- data.frame(hts10='1234567890',country='2010',
  statutory_base_rate=0.025,statutory_rate_232=0.25,statutory_total_rate=0.275,
  ch99_code_232='9903.81.90',ch99_code_301=NA_character_,
  duty_provenance_json='{"source":"x"}',ch99_rules_json='{"rule":"y"}',
  s232_suppressed_json=NA_character_,pending_activation_json=NA_character_,
  stringsAsFactors=FALSE)
agg <- mark_aggregate_only_scope(rates,'aggregate_only_build_no_shipment_contract_requested')
una <- mark_shipment_contract_unavailable(rates,'ordinary_build_missing_verified_shipment_projection')

# A loader must not be able to tell the two apart by shape. The retained-legacy
# and aggregate_* copies exist on both paths; only the values and the declared
# status differ.
stopifnot(identical(sort(names(agg)),sort(names(una))))

# Aggregate-only keeps what the aggregate pipeline produced.
stopifnot(identical(agg$statutory_base_rate,0.025),
          identical(agg$statutory_rate_232,0.25),
          identical(agg$statutory_total_rate,0.275),
          identical(agg$ch99_code_232,'9903.81.90'),
          identical(agg$duty_provenance_json,'{"source":"x"}'),
          identical(agg$ch99_rules_json,'{"rule":"y"}'))
# and still publishes the modeled figure under its honest name, so nothing is
# promoted to a source-backed claim by preserving it.
stopifnot(identical(agg$modeled_legacy_statutory_base_rate,0.025),
          identical(agg$aggregate_ch99_code_232,'9903.81.90'),
          identical(agg$shipment_status,'aggregate_only'),
          identical(agg$shipment_contract_version,'aggregate_modeled_no_shipment_contract'))

# The contract-expected path is unchanged: blank, with the value retained only
# under modeled_legacy_*/aggregate_*.
stopifnot(is.na(una$statutory_base_rate),is.na(una$statutory_rate_232),
          is.na(una$ch99_code_232),is.na(una$duty_provenance_json),
          identical(una$modeled_legacy_statutory_base_rate,0.025),
          identical(una$aggregate_ch99_code_232,'9903.81.90'),
          identical(una$shipment_status,'unresolved_source'),
          identical(una$shipment_contract_version,'unsupported_or_incomplete_contract'))

# Neither path may invent a shipment identity it does not have.
for(x in list(agg,una))
  stopifnot(is.na(x$shipment_dataset_version),is.na(x$shipment_evidence_snapshot_id),
            is.na(x$shipment_bundle_ids_json),is.na(x$shipment_decision_ids_json))

cat('Aggregate-only scope keeps its own statutory and Chapter 99 values;',
    'the contract-expected path still blanks them; schemas match\n')
