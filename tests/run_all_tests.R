# =============================================================================
# run_all_tests.R — run every test suite and summarise
# =============================================================================
#
# Suites are DISCOVERED from tests/*.R rather than listed, so a new suite is
# picked up automatically. A hardcoded list is how a suite gets written, then
# quietly stops being run.
#
# Some suites need built parquets and are skipped when the data is absent —
# reported as SKIP, never as a pass.
#
# Usage:
#   Rscript tests/run_all_tests.R
#   Rscript tests/run_all_tests.R --require-data   # treat skips as failures
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
require_data <- '--require-data' %in% args

test_dir <- if (dir.exists('tests')) 'tests' else '.'
suites <- sort(list.files(test_dir, pattern = '^(test_|run_tests_).*\\.R$',
                          full.names = TRUE))
suites <- suites[!grepl('run_all_tests\\.R$', suites)]

cat(strrep('=', 72), '\n')
cat('Running', length(suites), 'test suites\n')
cat(strrep('=', 72), '\n\n')

results <- list()
for (s in suites) {
  nm <- basename(s)
  cat('---', nm, '\n')
  out <- suppressWarnings(system2('Rscript', shQuote(s), stdout = TRUE, stderr = TRUE))
  status <- attr(out, 'status'); if (is.null(status)) status <- 0L

  line <- grep('^Tests:', out, value = TRUE)
  passed <- failed <- NA_integer_
  if (length(line)) {
    passed <- as.integer(sub('.*?([0-9]+)\\s+passed.*', '\\1', line[length(line)]))
    fm <- regmatches(line[length(line)], regexpr('([0-9]+)\\s+failed', line[length(line)]))
    failed <- if (length(fm)) as.integer(sub('\\D+', '', fm)) else 0L
  }

  # A suite that could not run for want of built data is a SKIP, not a pass.
  skipped <- status != 0L && is.na(passed) &&
    any(grepl('no parquet|not found|does not exist|no such file',
              out, ignore.case = TRUE))

  verdict <- if (skipped) 'SKIP'
             else if (is.na(passed)) 'ERROR'
             else if (failed > 0 || status != 0L) 'FAIL' else 'OK'

  if (verdict %in% c('FAIL', 'ERROR')) {
    cat(paste0('    ', utils::tail(out, 12), collapse = '\n'), '\n')
  }
  cat(sprintf('    [%s] %s\n\n', verdict,
              if (is.na(passed)) '' else sprintf('%d passed, %d failed', passed, failed)))

  results[[nm]] <- list(verdict = verdict, passed = passed, failed = failed)
}

cat(strrep('=', 72), '\n')
tot_p <- sum(vapply(results, function(r) if (is.na(r$passed)) 0L else r$passed, integer(1)))
tot_f <- sum(vapply(results, function(r) if (is.na(r$failed)) 0L else r$failed, integer(1)))
for (nm in names(results)) {
  r <- results[[nm]]
  cat(sprintf('  %-32s %-6s %s\n', nm, r$verdict,
              if (is.na(r$passed)) '' else sprintf('%d/%d', r$passed, r$passed + r$failed)))
}
cat(strrep('-', 72), '\n')
cat(sprintf('  TOTAL: %d passed, %d failed\n', tot_p, tot_f))

bad <- vapply(results, function(r) r$verdict %in% c('FAIL', 'ERROR'), logical(1))
skips <- vapply(results, function(r) r$verdict == 'SKIP', logical(1))
if (any(skips)) {
  cat(sprintf('  SKIPPED (needs built data): %s\n',
              paste(names(results)[skips], collapse = ', ')))
}
cat(strrep('=', 72), '\n')

if (any(bad) || (require_data && any(skips))) quit(status = 1)
