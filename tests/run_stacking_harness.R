# =============================================================================
# Stacking-Validation Harness — entrypoint
# =============================================================================
#
# Thin wrapper around tests/test_stacking_harness.R. Today it just sources the
# harness; once additional stacking-related test files exist they can be added
# here in order.
#
# Usage:
#   Rscript tests/run_stacking_harness.R
# =============================================================================

suppressPackageStartupMessages(library(here))

source(here('tests', 'test_stacking_harness.R'))
