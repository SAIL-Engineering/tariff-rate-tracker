# =============================================================================
# Build Annex II first-appearance dates from chapter 99 US-notes PDFs
# =============================================================================
#
# The IEEPA Annex II exempt list (resources/ieepa_exempt_products.csv) was
# static, so amendments — the Sept 5, 2025 EO 14346 additions (gold bullion
# etc.) and the Nov 14, 2025 agricultural expansion (coffee, tea, flowers,
# cocoa, palm oil, ...) — applied retroactively to earlier revisions
# (extreme-eta review item 3: Oct 2025 snapshots showed reciprocal = 0 on
# Colombia coffee months before the carve-out existed).
#
# This script extracts the note 2(v)(iii)(a) enumeration (the "9903.01.32 ...
# shall not apply to products classified in the following" list) from every
# local chapter99_<revision>.pdf, tracks each code prefix's FIRST appearance,
# and writes:
#   resources/annex_ii_first_appearance.csv  (prefix, first_revision, date)
# then stamps resources/ieepa_exempt_products.csv with an
# effective_date_start column: NA for entries present in the first Annex II
# text (or entries not traceable to the enumeration — ch98 statutory, Berman
# ch49/97), else the effective date of the revision where their longest
# matching prefix first appeared (minimum across matching prefixes).
#
# Known caveat: dates reflect when the text entered the HTS, which can lag
# the legal effective date by a few days (e.g. the Apr 11, 2025 electronics
# memo was retroactive to Apr 5). The tracker snaps to revision effective
# dates anyway, so this only matters within a single revision window.
#
# Usage: Rscript scripts/build_annex_ii_dates.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

if (!requireNamespace('pdftools', quietly = TRUE)) {
  stop('pdftools package required')
}

rev_dates <- read_csv(here('config', 'revision_dates.csv'),
                      col_types = cols(.default = col_character())) %>%
  mutate(effective_date = as.Date(effective_date)) %>%
  arrange(effective_date)

pdf_for_revision <- function(rev) {
  here('data', 'us_notes', paste0('chapter99_', rev, '.pdf'))
}

# --- Extract the (iii)(a) enumeration code set from one PDF ---
HEADER_PATTERNS <- paste(
  'Harmonized Tariff Schedule', 'Annotated for Statistical',
  'U\\.S\\. Notes', '^[IVXLC]+$', '^99\\s*-\\s*III', 'Compiler', 'Revision \\d+',
  sep = '|'
)

extract_annex_ii_codes <- function(pdf_path) {
  pages <- pdftools::pdf_text(pdf_path)
  lines <- unlist(strsplit(paste(pages, collapse = '\n'), '\n'))
  lines <- trimws(lines)

  # Anchor: the (iii)/(iii)(a) header sentence. It references heading
  # 9903.01.32 and contains "shall not apply to products classified in the
  # following". The sentence wraps across 2-4 lines depending on vintage.
  anchor <- NA_integer_
  hits <- grep('9903\\.01\\.32', lines)
  for (h in hits) {
    window <- paste(lines[h:min(h + 5, length(lines))], collapse = ' ')
    if (grepl('shall not apply to products\\s+classified in the following', window)) {
      # Start collecting after the line containing 'following'
      tail_off <- grep('following', lines[h:min(h + 6, length(lines))])[1]
      anchor <- h + tail_off - 1
      break
    }
  }
  if (is.na(anchor)) return(character(0))

  # Walk the enumeration. Page headers, footers, and compiler notes are
  # interleaved mid-list, so prose lines are SKIPPED, not terminators.
  # The list ends at the next subdivision marker ('(b)', '(iv)', ...)
  # followed by text on the same line. Bracketed compiler notes can span
  # lines — track open-bracket state.
  codes <- character(0)
  in_bracket <- FALSE
  i <- anchor + 1
  max_i <- min(anchor + 3000, length(lines))
  while (i <= max_i) {
    ln <- lines[i]
    i <- i + 1
    if (ln == '') next

    if (in_bracket) {
      if (grepl('\\]', ln)) in_bracket <- FALSE
      next
    }
    if (grepl('\\[', ln) && !grepl('\\]', ln)) {
      in_bracket <- TRUE
      next
    }
    if (grepl('\\[.*\\]', ln)) next                     # one-line bracket note

    # Terminator: next subdivision marker with text on the same line.
    if (grepl('^\\([a-z]\\)\\s+\\S|^\\([ivxl]+\\)\\s+\\S', ln)) break

    if (grepl(HEADER_PATTERNS, ln)) next
    if (grepl('^\\d+$', ln)) next                       # bare page numbers
    if (grepl('^\\([a-z]\\)$|^\\([ivxl]+\\)$', ln)) next  # bare markers

    n_alpha <- nchar(gsub('[^A-Za-z]', '', ln))
    # Dotted codes: 6, 8 or 10 digits
    dotted <- regmatches(ln, gregexpr('\\d{4}(\\.\\d{2}){1,3}', ln))[[1]]
    # Bare 4-digit headings (e.g. 8471, 8486) only on code-dominated lines
    bare <- if (n_alpha <= 12) {
      regmatches(ln, gregexpr('(?<![\\d.])\\d{4}(?![\\d.])', ln, perl = TRUE))[[1]]
    } else {
      character(0)
    }
    if (length(dotted) == 0 && length(bare) == 0) next  # prose/header: skip
    codes <- c(codes, gsub('\\.', '', dotted), bare)
  }
  unique(codes)
}

# --- Walk all revisions chronologically ---
results <- list()
for (k in seq_len(nrow(rev_dates))) {
  rev <- rev_dates$revision[k]
  pdf <- pdf_for_revision(rev)
  if (!file.exists(pdf)) {
    message(sprintf('%-14s : no PDF, skipped', rev))
    next
  }
  codes <- extract_annex_ii_codes(pdf)
  results[[rev]] <- codes
  message(sprintf('%-14s (%s): %d codes', rev,
                  rev_dates$effective_date[k], length(codes)))
}

with_list <- names(results)[lengths(results) > 0]
if (length(with_list) == 0) stop('No Annex II enumeration found in any PDF')
baseline_rev <- with_list[1]
message('\nBaseline (first revision with Annex II): ', baseline_rev)

# --- Legal amendment dates (from data/hts_change_record/) ---
# The revision_dates.csv effective dates for rev_25-31 are mis-aligned with
# the official change records (see todo.md, revision re-dating item), and
# amendments can be retroactive. Stamp with the LEGAL effective date of the
# note 2(v)(iii) modification, verified per change record:
#   rev_10: April 5, 2025      (electronics memo, Executive Memoranda — retroactive)
#   rev_22: September 8, 2025  (EO 14346 metals/gold additions + removals)
#   rev_29: November 13, 2025  (agricultural expansion EO)
# Removals (codes exempt through the day before the removal took effect):
#   rev_17: effective August 1, 2025    (PP 10962 — copper moved to 232)
#   rev_22: effective September 8, 2025 (EO 14346)
#   rev_25: effective October 14, 2025  (PP 10976 — wood moved to 232)
START_OVERRIDES <- c(
  rev_10 = '2025-04-05',
  rev_22 = '2025-09-08',
  rev_29 = '2025-11-13'
)
END_OVERRIDES <- c(   # keyed by the revision where the code first DISAPPEARS
  rev_17 = '2025-07-31',
  rev_22 = '2025-09-07',
  rev_25 = '2025-10-13'
)

legal_date_for <- function(rev, overrides) {
  if (rev %in% names(overrides)) {
    as.Date(overrides[[rev]])
  } else {
    d <- rev_dates$effective_date[rev_dates$revision == rev]
    message('  NOTE: no change-record override for ', rev,
            ' — using revision_dates.csv date ', d,
            '. Verify against data/hts_change_record/.')
    d
  }
}

# --- First / last appearance per prefix ---
first_seen <- list()
last_seen <- list()
for (rev in with_list) {
  for (code in results[[rev]]) {
    if (is.null(first_seen[[code]])) first_seen[[code]] <- rev
    last_seen[[code]] <- rev
  }
}

final_rev <- with_list[length(with_list)]
rev_index <- setNames(seq_along(with_list), with_list)

# Reappearance check: a code absent in some middle revision but present later
# would need interval support — skip end-dating those and warn.
reappears <- character(0)
for (code in names(first_seen)) {
  fi <- rev_index[[first_seen[[code]]]]
  li <- rev_index[[last_seen[[code]]]]
  present <- map_lgl(with_list[fi:li], ~code %in% results[[.x]])
  if (!all(present)) reappears <- c(reappears, code)
}
if (length(reappears) > 0) {
  message('WARNING: ', length(reappears),
          ' codes disappear and reappear (no end-dating applied): ',
          paste(head(reappears, 10), collapse = ', '))
}

first_appearance <- tibble(
  prefix = names(first_seen),
  first_revision = map_chr(first_seen, identity),
  last_revision = map_chr(last_seen, identity)
) %>%
  mutate(
    first_effective_date = map(first_revision, function(r) {
      if (r == baseline_rev) as.Date(NA) else legal_date_for(r, START_OVERRIDES)
    }) %>% reduce(c),
    removed_at = map_chr(last_revision, function(r) {
      if (r == final_rev) return(NA_character_)
      with_list[rev_index[[r]] + 1]   # revision where it first disappears
    }),
    end_effective_date = map(removed_at, function(r) {
      if (is.na(r)) as.Date(NA) else legal_date_for(r, END_OVERRIDES)
    }) %>% reduce(c),
    end_effective_date = if_else(prefix %in% reappears,
                                 as.Date(NA), end_effective_date)
  ) %>%
  arrange(prefix)

out_fa <- here('resources', 'annex_ii_first_appearance.csv')
write_csv(first_appearance, out_fa)
message('Wrote ', out_fa, ' (', nrow(first_appearance), ' prefixes)')

# --- Diff summary for the two known amendment windows ---
report_diff <- function(rev_a, rev_b) {
  if (!rev_a %in% with_list || !rev_b %in% with_list) return(invisible())
  added <- setdiff(results[[rev_b]], results[[rev_a]])
  removed <- setdiff(results[[rev_a]], results[[rev_b]])
  message('\n', rev_a, ' -> ', rev_b, ': +', length(added), ' / -', length(removed))
  if (length(added) > 0) {
    message('  added (by HS2): ',
            paste(names(sort(table(substr(added, 1, 2)), decreasing = TRUE)),
                  sort(table(substr(added, 1, 2)), decreasing = TRUE),
                  sep = ':', collapse = ' '))
  }
}
report_diff('rev_31', 'rev_32')   # Nov 14, 2025 agricultural expansion
report_diff('rev_23', 'rev_24')   # Sept 5, 2025 EO 14346 window
report_diff('rev_24', 'rev_25')

# --- Stamp the exempt list ---
exempt_file <- here('resources', 'ieepa_exempt_products.csv')
exempt <- read_csv(exempt_file, col_types = cols(hts10 = col_character(),
                                                 .default = col_character())) %>%
  select(hts10)

# For each exempt HTS10: the earliest first-appearance date among matching
# prefixes (baseline coverage wins -> NA = always active). Entries matching
# no prefix at all (ch98 statutory, Berman ch49/97) also get NA. End dates:
# the matching prefix's end, taken from the LONGEST (most specific) match so
# a specific re-listed subheading can outlive a removed broader prefix.
fa_added <- first_appearance %>% filter(first_revision != baseline_rev)
baseline_prefixes <- first_appearance$prefix[first_appearance$first_revision == baseline_rev]

stamp_one <- function(hts10) {
  matches <- first_appearance %>% filter(startsWith(hts10, prefix))
  if (nrow(matches) == 0) {
    return(list(start = as.Date(NA), end = as.Date(NA)))
  }
  start <- if (any(matches$first_revision == baseline_rev)) {
    as.Date(NA)
  } else {
    min(matches$first_effective_date)
  }
  longest <- matches %>% slice_max(nchar(prefix), n = 1, with_ties = FALSE)
  list(start = start, end = longest$end_effective_date)
}

message('\nStamping ', nrow(exempt), ' exempt entries...')
stamped <- map(exempt$hts10, stamp_one)
exempt$effective_date_start <- as.Date(map_dbl(stamped, ~as.numeric(.x$start)))
exempt$effective_date_end <- as.Date(map_dbl(stamped, ~as.numeric(.x$end)))

# --- Append HTS10 children of REMOVED prefixes missing from the list ---
# (e.g. PP 10976 wood products: on Annex II Apr-Oct 2025, removed when 232
# wood coverage began. The current list post-dates the removal, so these
# products' Apr-Oct exemption window was missing entirely.)
removed <- first_appearance %>% filter(!is.na(end_effective_date))
if (nrow(removed) > 0) {
  universe <- character(0)
  for (f in c(here('data', 'processed', 'products_rev_32.rds'),
              here('data', 'processed', 'products_2026_rev_9.rds'))) {
    if (file.exists(f)) universe <- c(universe, readRDS(f)$hts10)
  }
  universe <- unique(universe)
  add_rows <- map_dfr(seq_len(nrow(removed)), function(j) {
    kids <- universe[startsWith(universe, removed$prefix[j])]
    tibble(hts10 = kids,
           effective_date_start = removed$first_effective_date[j],
           effective_date_end = removed$end_effective_date[j])
  }) %>%
    distinct(hts10, .keep_all = TRUE) %>%
    filter(!hts10 %in% exempt$hts10)
  message('Appending ', nrow(add_rows), ' HTS10 children of ',
          nrow(removed), ' removed prefixes (windowed exemptions)')
  print(add_rows %>% count(hs2 = substr(hts10, 1, 2), effective_date_end))
  exempt <- bind_rows(exempt, add_rows) %>% arrange(hts10)
}

# --- Remove ch06 Swiss-annex contamination from the universal list ---
# Chapter 6 (live plants / cut flowers) never appears in the universal
# (iii)(a) enumeration in ANY revision; it appears exactly on the
# Switzerland/Liechtenstein framework annex (note 2(v) Swiss subdivisions,
# 2026 notes; captured in data/us_notes/floor_exempt_2026_*.csv with
# country_group='swiss'). The universal list inherited these via the Feb 2026
# ETRs alignment, wrongly exempting flowers for ALL countries — the
# negative-eta ch06 cluster in the extreme-eta review traces here, not to
# the Nov 13 ag expansion. Swiss imports stay exempt via the floor-exemption
# path. Other chapters with no (iii)(a) provenance (ch29 pharma, ch84/85)
# are deliberate TPC/CSMS-aligned breadth and are NOT touched.
swiss_floor_path <- here('data', 'us_notes', 'floor_exempt_2026_basic.csv')
if (file.exists(swiss_floor_path)) {
  swiss_prefixes <- read_csv(swiss_floor_path,
                             col_types = cols(.default = col_character())) %>%
    filter(country_group == 'swiss') %>%
    pull(hts8) %>% unique()
  matches_iiia <- map_lgl(exempt$hts10,
                          function(h) any(startsWith(h, first_appearance$prefix)))
  is_ch06_swiss <- substr(exempt$hts10, 1, 2) == '06' & !matches_iiia &
    map_lgl(exempt$hts10, function(h) any(startsWith(h, swiss_prefixes)))
  if (any(is_ch06_swiss)) {
    message('Removing ', sum(is_ch06_swiss),
            ' ch06 Swiss-annex-only entries from the universal list')
    exempt <- exempt %>% filter(!is_ch06_swiss)
  }
}

n_dated <- sum(!is.na(exempt$effective_date_start))
n_ended <- sum(!is.na(exempt$effective_date_end))
message('Entries with start dates: ', n_dated, '; with end dates: ', n_ended,
        '; total: ', nrow(exempt))
print(exempt %>% filter(!is.na(effective_date_start)) %>%
        count(hs2 = substr(hts10, 1, 2), effective_date_start) %>%
        arrange(effective_date_start, hs2), n = 50)

write_csv(exempt, exempt_file)
message('Wrote ', exempt_file)
