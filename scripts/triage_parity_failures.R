# =============================================================================
# triage_parity_failures.R
# =============================================================================
#
# Groups failures from tests/test_normalized_parity.R output into actionable
# buckets so each iteration of the parity loop spends its budget on the most
# impactful bug class, not on chasing duplicate symptoms.
#
# Input: captured stdout of test_normalized_parity.R, or a file of [FAIL]
#        lines in the same format that the harness emits at line 267-270:
#
#   [FAIL]  <hts10>/<country>/<revision> <column>: denorm=<a> norm=<b> diff=<d>
#
# Output:
#   1. Console: ranked table of failure buckets (signature -> count)
#   2. tests/parity_failures_triaged.csv: one representative case per signature
#      suitable for targeted debugging or for seeding a --targeted re-run
#
# Signature definition (the bucket key): we hash the observed divergence to
# collapse symptoms that share a root cause. The signature is a 4-tuple:
#
#   (column, sign, denorm_bucket, diff_bucket)
#
# where:
#   - column     = the failing rate field (rate_232, rate_ieepa_recip, etc.)
#   - sign       = '+' if norm > denorm, '-' otherwise (which side is over)
#   - denorm_bucket = the denorm value rounded to 3 decimal places — two cases
#                     with denorm=0.125 cluster together
#   - diff_bucket   = the diff rounded to 3 decimal places — cases with the
#                     same magnitude share a likely root cause
#
# Usage:
#   Rscript scripts/triage_parity_failures.R \
#     --input  output/logs/parity_latest.log \
#     --output tests/parity_failures_triaged.csv
#
#   # Or pipe directly from a live run:
#   Rscript tests/test_normalized_parity.R | \
#     Rscript scripts/triage_parity_failures.R --input - --output triaged.csv
#
#   # Or just feed the stdout capture that's already been saved:
#   Rscript scripts/triage_parity_failures.R --input /tmp/harness.out
# =============================================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tibble)
  library(stringr)
})

args <- commandArgs(trailingOnly = TRUE)

arg_value <- function(flag, default = NULL) {
  idx <- which(args == flag)
  if (length(idx) == 0 || idx[1] >= length(args)) return(default)
  args[idx[1] + 1]
}

input_path  <- arg_value('--input',  default = NULL)
output_path <- arg_value('--output', default = 'tests/parity_failures_triaged.csv')
top_n       <- as.integer(arg_value('--top', default = '20'))

if (is.null(input_path)) {
  stop('--input is required. Use - for stdin, or a file path.')
}

lines <- if (input_path == '-') {
  readLines(file('stdin'))
} else if (!file.exists(input_path)) {
  stop('Input file not found: ', input_path)
} else {
  readLines(input_path, warn = FALSE)
}

# Expected failure line format from tests/test_normalized_parity.R:267-270:
#   [FAIL]  8708292500/4759/2025_rev_24 total_rate: denorm=0.14983 norm=0.262455 diff=0.112625
#
# Allow for a couple spaces of slop and for scientific notation in the numbers.
fail_re <- paste0(
  '^\\[FAIL\\]\\s+',
  '([0-9]{10})/([0-9A-Za-z_]+)/([0-9A-Za-z_]+)\\s+',
  '([a-z_0-9]+):\\s+',
  'denorm=([0-9eE.+\\-]+)\\s+',
  'norm=([0-9eE.+\\-]+)\\s+',
  'diff=([0-9eE.+\\-]+)$'
)

matches <- str_match(lines, fail_re)
fail_idx <- which(!is.na(matches[, 1]))

if (length(fail_idx) == 0) {
  message('No [FAIL] lines matched. Nothing to triage.')
  message('Check input format; harness emits lines like:')
  message('  [FAIL]  8708292500/4759/2025_rev_24 total_rate: denorm=0.14983 norm=0.262455 diff=0.112625')
  quit(status = 0)
}

failures <- tibble(
  hts10    = matches[fail_idx, 2],
  country  = matches[fail_idx, 3],
  revision = matches[fail_idx, 4],
  column   = matches[fail_idx, 5],
  denorm   = as.numeric(matches[fail_idx, 6]),
  norm     = as.numeric(matches[fail_idx, 7]),
  diff     = as.numeric(matches[fail_idx, 8])
) %>%
  mutate(
    # sign of divergence: which side is over
    sign          = if_else(norm > denorm, '+', '-'),
    # bucket the magnitudes so cosmetically different values cluster on the
    # same root cause (0.237625 vs 0.237624 hash to the same bucket)
    denorm_bucket = round(denorm, 3),
    diff_bucket   = round(diff, 3),
    signature     = paste(column, sign, denorm_bucket, diff_bucket, sep = '|')
  )

# --- Bucket summary ---
buckets <- failures %>%
  group_by(signature, column, sign, denorm_bucket, diff_bucket) %>%
  summarise(
    count      = dplyr::n(),
    # representative case — pick the first one in stable order so reruns
    # diagnose the same row
    repr_hts10    = first(hts10),
    repr_country  = first(country),
    repr_revision = first(revision),
    repr_denorm   = first(denorm),
    repr_norm     = first(norm),
    repr_diff     = first(diff),
    .groups = 'drop'
  ) %>%
  arrange(desc(count), desc(abs(diff_bucket)))

# --- Column-level roll-up for the ranked table ---
by_column <- failures %>%
  count(column, sort = TRUE, name = 'count')

# --- Console report ---
total_fail <- nrow(failures)
total_sig  <- nrow(buckets)
cat('\n=== Parity failure triage ===\n')
cat('Total failure lines: ', total_fail, '\n', sep = '')
cat('Distinct signatures: ', total_sig, '\n', sep = '')
cat('Top failing columns:\n')
for (i in seq_len(nrow(by_column))) {
  cat(sprintf('  %-24s %5d\n', by_column$column[i], by_column$count[i]))
}

cat('\nTop ', min(top_n, nrow(buckets)), ' buckets (count | column | sign | denorm~ | diff~ | repr):\n', sep = '')
cat(strrep('-', 90), '\n', sep = '')
for (i in seq_len(min(top_n, nrow(buckets)))) {
  b <- buckets[i, ]
  cat(sprintf(
    '%5d  %-22s %s  denorm~%.3f  diff~%.3f   %s/%s/%s\n',
    b$count, b$column, b$sign, b$denorm_bucket, b$diff_bucket,
    b$repr_hts10, b$repr_country, b$repr_revision
  ))
}

# --- Write representative cases CSV ---
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
out <- buckets %>%
  transmute(
    signature,
    count,
    column,
    sign,
    denorm_bucket,
    diff_bucket,
    hts10    = repr_hts10,
    country  = repr_country,
    revision = repr_revision,
    denorm   = repr_denorm,
    norm     = repr_norm,
    diff     = repr_diff
  )
write_csv(out, output_path)
cat('\nWrote ', nrow(out), ' representative cases to ', output_path, '\n', sep = '')
cat('Feed back into the harness with:\n')
cat('  Rscript tests/test_normalized_parity.R --cases ', output_path, '\n', sep = '')
