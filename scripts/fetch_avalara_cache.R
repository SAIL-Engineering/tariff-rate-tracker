# =============================================================================
# fetch_avalara_cache.R — pull cached Avalara payloads for a set of HTS codes
# =============================================================================
#
# `avalara_pair_cache` is ONE row per (hts10, origin_alpha2), not one per date.
# Each row holds the whole timeline for that pair inside `raw_response`, plus
# the window it covers:
#
#   coverage_start   2019-01-01 on every row observed
#   coverage_end     the fetch date — anything later is NOT in the cache
#
# Reads require an authenticated session: the RLS policy is
# `using (auth.uid() is not null)`, so the anon key returns HTTP 200 with ZERO
# rows — indistinguishable from "nothing cached" unless you know to look. The
# service-role key in the sail-gtx server env bypasses RLS.
#
# The key is read from the env file at run time and is never printed, echoed,
# or written to any output.
#
# Usage:
#   Rscript scripts/fetch_avalara_cache.R --entries data/validation/entries.csv
#   Rscript scripts/fetch_avalara_cache.R --entries <f> --out <path.rds>
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(jsonlite)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
arg_of <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (length(i) && length(args) > i[1]) args[i[1] + 1] else default
}

entries_path <- arg_of('--entries', here('data', 'validation', 'entries.csv'))
out_path     <- arg_of('--out', here('data', 'validation', 'avalara_cache.rds'))
env_path     <- arg_of('--env', file.path(
  '/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease',
  'sail-gtx-prerelease', 'server', '.env'))

# --- credentials --------------------------------------------------------------
read_env <- function(path, key) {
  if (!file.exists(path)) return(NA_character_)
  ln <- grep(paste0('^', key, '='), readLines(path, warn = FALSE), value = TRUE)
  if (!length(ln)) return(NA_character_)
  trimws(gsub('^[^=]+=', '', ln[1])) |> gsub(pattern = '^["\']|["\']$', replacement = '')
}

sb_url <- Sys.getenv('SUPABASE_URL', unset = NA_character_)
sb_key <- Sys.getenv('SUPABASE_SERVICE_ROLE_KEY', unset = NA_character_)
if (is.na(sb_url) || !nzchar(sb_url)) sb_url <- read_env(env_path, 'SUPABASE_URL')
if (is.na(sb_key) || !nzchar(sb_key)) sb_key <- read_env(env_path, 'SUPABASE_SERVICE_ROLE_KEY')

if (is.na(sb_url) || is.na(sb_key) || !nzchar(sb_url) || !nzchar(sb_key)) {
  stop('No Supabase credentials.\n',
       '  Looked for SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY in the environment,\n',
       '  then in ', env_path, '\n',
       '  The ANON key will NOT work: RLS on avalara_pair_cache requires\n',
       '  auth.uid() is not null, so it returns 200 with zero rows.',
       call. = FALSE)
}
message('Supabase host: ', sub('^https?://([^.]+).*', '\\1…', sb_url))

# --- which pairs do we need? --------------------------------------------------
entries <- suppressMessages(read_csv(entries_path, show_col_types = FALSE))
names(entries) <- tolower(gsub('\\s+', '_', names(entries)))
stopifnot(all(c('hts', 'countryorigin', 'entry_date') %in% names(entries)))
entries <- entries %>%
  transmute(hts10 = sprintf('%010s', gsub('\\D', '', hts)),
            origin_alpha2 = toupper(trimws(countryorigin)),
            entry_date = as.Date(entry_date))

codes <- sort(unique(entries$hts10))
message('Entries: ', nrow(entries), ' rows | ', length(codes), ' HTS codes | ',
        nrow(distinct(entries, hts10, origin_alpha2)), ' pairs')

# --- fetch --------------------------------------------------------------------
# Filter server-side on hts10 so we transfer only what the entry list needs.
# raw_response is large, so page rather than pull everything at once.
fetch_chunk <- function(chunk) {
  url <- paste0(
    sb_url, '/rest/v1/avalara_pair_cache',
    '?select=hts10,origin_alpha2,coverage_start,coverage_end,',
    'latest_revision_effective_date,fetched_at,raw_response',
    '&hts10=in.(', paste(chunk, collapse = ','), ')')
  h <- c(apikey = sb_key, Authorization = paste('Bearer', sb_key))
  con <- url(url, headers = h)
  on.exit(try(close(con), silent = TRUE), add = TRUE)
  txt <- tryCatch(paste(readLines(con, warn = FALSE), collapse = ''),
                  error = function(e) NA_character_)
  if (is.na(txt) || !nzchar(txt)) return(list())
  jsonlite::fromJSON(txt, simplifyVector = FALSE)
}

chunks <- split(codes, ceiling(seq_along(codes) / 12))
rows <- list()
for (i in seq_along(chunks)) {
  r <- fetch_chunk(chunks[[i]])
  rows <- c(rows, r)
  message('  chunk ', i, '/', length(chunks), ' -> ', length(r),
          ' rows (total ', length(rows), ')')
}

if (length(rows) == 0) {
  stop('Zero rows returned. If the credentials were the ANON key this is what ',
       'RLS looks like — a clean 200 with nothing in it.', call. = FALSE)
}

cache <- tibble(
  hts10         = map_chr(rows, ~ .x$hts10 %||% NA_character_),
  origin_alpha2 = map_chr(rows, ~ .x$origin_alpha2 %||% NA_character_),
  coverage_start = as.Date(map_chr(rows, ~ .x$coverage_start %||% NA_character_)),
  coverage_end   = as.Date(map_chr(rows, ~ .x$coverage_end %||% NA_character_)),
  latest_revision_effective_date =
    as.Date(map_chr(rows, ~ .x$latest_revision_effective_date %||% NA_character_)),
  fetched_at    = map_chr(rows, ~ .x$fetched_at %||% NA_character_),
  raw_response  = map(rows, ~ .x$raw_response)
)

# --- coverage report ----------------------------------------------------------
need <- distinct(entries, hts10, origin_alpha2)
have <- distinct(cache, hts10, origin_alpha2) %>% mutate(.in_cache = TRUE)
cov  <- need %>% left_join(have, by = c('hts10', 'origin_alpha2')) %>%
  mutate(.in_cache = coalesce(.in_cache, FALSE))

message('\nPairs needed: ', nrow(cov), ' | in cache: ', sum(cov$.in_cache),
        ' | missing: ', sum(!cov$.in_cache))
if (any(!cov$.in_cache)) {
  miss <- cov %>% filter(!.in_cache)
  message('  missing pairs (rows will be reported as gap_no_pair):')
  for (i in seq_len(min(10, nrow(miss)))) {
    message('    ', miss$hts10[i], '  ', miss$origin_alpha2[i])
  }
}

# Entry dates outside the cached window cannot be compared.
win <- entries %>% inner_join(cache %>% select(hts10, origin_alpha2,
                                               coverage_start, coverage_end),
                              by = c('hts10', 'origin_alpha2'))
n_after <- sum(win$entry_date > win$coverage_end, na.rm = TRUE)
n_before <- sum(win$entry_date < win$coverage_start, na.rm = TRUE)
message('Entry dates outside the cached window: ', n_after, ' after coverage_end, ',
        n_before, ' before coverage_start')

saveRDS(cache, out_path)
message('\nWrote ', out_path, ' — ', nrow(cache), ' pair payloads')
