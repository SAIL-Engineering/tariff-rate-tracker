# =============================================================================
# Tests for swap_in_dir (src/helpers.R): the parquet combine builds its new
# dataset beside the live one and swaps it in only when complete.
# Run: Rscript tests/test_swap_in_dir.R
# =============================================================================

suppressMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'helpers.R'))

pass_count <- 0; fail_count <- 0
run_test <- function(name, expr) {
  tryCatch({ force(expr); message('  PASS: ', name); pass_count <<- pass_count + 1 },
           error = function(e) { message('  FAIL: ', name, ' — ', conditionMessage(e))
                                 fail_count <<- fail_count + 1 })
}

fresh <- function() {
  root <- tempfile('swap-'); dir.create(root)
  final <- file.path(root, 'rate_timeseries_parquet')
  list(root = root, final = final, staging = paste0(final, '.partial'))
}
put <- function(dir, name, text) {
  dir.create(file.path(dir, name), recursive = TRUE, showWarnings = FALSE)
  writeLines(text, file.path(dir, name, 'data.parquet'))
}
read <- function(dir, name) readLines(file.path(dir, name, 'data.parquet'))

message('swap_in_dir')

run_test('replaces the live dataset and removes the old copy', {
  d <- fresh()
  put(d$final, 'revision=r1', 'old r1'); put(d$final, 'revision=r9', 'removed revision')
  put(d$staging, 'revision=r1', 'new r1'); put(d$staging, 'revision=r2', 'new r2')
  swap_in_dir(d$staging, d$final)
  stopifnot(identical(read(d$final, 'revision=r1'), 'new r1'),
            identical(read(d$final, 'revision=r2'), 'new r2'),
            !dir.exists(file.path(d$final, 'revision=r9')),
            !dir.exists(d$staging), !dir.exists(paste0(d$final, '.old')))
})

run_test('works when there is no live dataset yet', {
  d <- fresh()
  put(d$staging, 'revision=r1', 'new r1')
  swap_in_dir(d$staging, d$final)
  stopifnot(identical(read(d$final, 'revision=r1'), 'new r1'), !dir.exists(d$staging))
})

run_test('a missing staging directory leaves the live dataset untouched', {
  d <- fresh()
  put(d$final, 'revision=r1', 'old r1')
  failed <- tryCatch({ swap_in_dir(d$staging, d$final); FALSE }, error = function(e) TRUE)
  stopifnot(failed, identical(read(d$final, 'revision=r1'), 'old r1'))
})

run_test('a stale .old from an earlier crash does not block the swap', {
  d <- fresh()
  put(d$final, 'revision=r1', 'old r1')
  put(paste0(d$final, '.old'), 'revision=r0', 'leftover')
  put(d$staging, 'revision=r1', 'new r1')
  swap_in_dir(d$staging, d$final)
  stopifnot(identical(read(d$final, 'revision=r1'), 'new r1'),
            !dir.exists(paste0(d$final, '.old')))
})

message('\n', pass_count, ' passed, ', fail_count, ' failed')
if (fail_count > 0) quit(status = 1)
