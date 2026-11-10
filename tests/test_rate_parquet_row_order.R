# =============================================================================
# test_rate_parquet_row_order.R — write_rate_parquet(row_order=) must write the
# SAME BYTES arrange() would, without a second copy of the frame.
# =============================================================================
#
# The combine used to sort each revision with arrange(valid_from,country,hts10)
# and hand the sorted frame to the writer. arrange() returns a second full
# frame, so the loop held two copies of a revision at once -- 28.1 GB each on
# 2026_rev_22's four legal states (19,605,120 rows x 185 cols), 56 GB on a 62 GB
# machine -- and the OOM killer took it at [138/145]. The order now travels as
# an integer permutation (78 MB at that size) applied one row group at a time.
#
# That is only safe while the permutation orders rows EXACTLY as arrange() did,
# including ties and NA, or partitions silently change row order between builds.
# Base radix and dplyr both collate character in the C locale, sort NA last and
# are stable, so this asserts byte-identical output rather than trusting that.
# =============================================================================
suppressPackageStartupMessages({library(dplyr); library(arrow)})
source('src/helpers.R')

pass <- 0L; fail <- 0L
ok <- function(what, cond) {
  if (isTRUE(cond)) { pass <<- pass + 1L } else {
    fail <<- fail + 1L; cat('  FAIL:', what, '\n')
  }
}

out <- tempfile(); dir.create(out)
on.exit(unlink(out, recursive = TRUE), add = TRUE)

# Ties on every key, NA in every key, and a payload that exposes tie-break order.
set.seed(11)
n <- 20000L
d <- data.frame(
  valid_from = as.Date('2026-10-30') + sample(c(0L, 1L, 7L, NA), n, TRUE),
  country    = sample(c('5700', '1220', '4120', 'ZZ', NA), n, TRUE),
  hts10      = sample(c('0101210010', '9903010101', '72082719', NA), n, TRUE),
  base_rate  = runif(n),
  calc_status = sample(c('ok', 'base_not_representable', NA), n, TRUE),
  payload    = seq_len(n),
  stringsAsFactors = FALSE)

ok('fixture exercises ties', sum(duplicated(d[, c('valid_from','country','hts10')])) > 1000L)
ok('fixture exercises NA keys', anyNA(d$valid_from) && anyNA(d$country) && anyNA(d$hts10))

ord <- order(d$valid_from, d$country, d$hts10, method = 'radix', na.last = TRUE)

# The permutation must reproduce arrange() across every column, payload included
# -- payload differing would mean ties resolved in a different order.
a <- dplyr::arrange(d, valid_from, country, hts10)
b <- d[ord, , drop = FALSE]
rownames(a) <- NULL; rownames(b) <- NULL
ok('permutation equals arrange() on all columns', isTRUE(all.equal(a, b, check.attributes = FALSE)))
ok('permutation equals arrange() on tie-break order', identical(a$payload, b$payload))

# ... and the writer must put those bytes on disk.
p_old <- file.path(out, 'old.parquet'); p_new <- file.path(out, 'new.parquet')
write_rate_parquet(a, p_old, rows_per_chunk = 4096, compression = 'zstd', compression_level = 3L)
write_rate_parquet(d, p_new, rows_per_chunk = 4096, compression = 'zstd', compression_level = 3L,
                   row_order = ord)
ok('row_order writes byte-identical parquet',
   identical(tools::md5sum(p_old)[[1]], tools::md5sum(p_new)[[1]]))

# Chunking must not reorder across row-group boundaries: a chunk size that does
# not divide the row count is the case that would drop or duplicate a tail.
p_odd <- file.path(out, 'odd.parquet')
write_rate_parquet(d, p_odd, rows_per_chunk = 3333, compression = 'zstd', compression_level = 3L,
                   row_order = ord)
rt <- as.data.frame(arrow::read_parquet(p_odd))
ok('ragged chunking preserves row count', nrow(rt) == n)
ok('ragged chunking preserves order', identical(rt$payload, a$payload))

# row_order = NULL must leave the frame alone.
p_null <- file.path(out, 'null.parquet')
write_rate_parquet(d, p_null, rows_per_chunk = 4096, compression = 'zstd', compression_level = 3L,
                   row_order = NULL)
ok('row_order = NULL writes df unsorted',
   identical(as.data.frame(arrow::read_parquet(p_null))$payload, d$payload))

# A non-permutation would silently drop or duplicate rows; it must stop instead.
bad_len <- try(write_rate_parquet(d, file.path(out, 'x.parquet'), row_order = 1:5), silent = TRUE)
ok('wrong-length row_order errors', inherits(bad_len, 'try-error'))
o_na <- ord; o_na[1] <- NA_integer_
bad_na <- try(write_rate_parquet(d, file.path(out, 'x.parquet'), row_order = o_na), silent = TRUE)
ok('NA in row_order errors', inherits(bad_na, 'try-error'))

# Empty frames still go through the n == 0 branch.
p_e <- file.path(out, 'empty.parquet')
write_rate_parquet(d[0, , drop = FALSE], p_e, row_order = integer(0))
ok('empty frame writes zero rows', nrow(as.data.frame(arrow::read_parquet(p_e))) == 0L)

cat(sprintf('Tests: %d passed, 0 skipped, %d failed\n', pass, fail))
if (fail > 0L) quit(status = 1L)
