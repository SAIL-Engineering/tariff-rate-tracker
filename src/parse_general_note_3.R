# =============================================================================
# parse_general_note_3.R — de-hardcode the rate universe from HTSUS General Note 3
# =============================================================================
# Fetches General Note 3 per revision from the USITC reststop file API (the SAME
# mechanism src/scrape_us_notes.R uses for Chapter 99) and parses:
#   * 3(b)  -> the Column 2 (non-NTR) country list
#   * 3(c)(i) -> the Special-program symbol map (symbol -> program name)
# Emits provenance-carrying CSVs to resources/ so the frontend program/Column-2
# tables stop being hardcoded. Coverage: reststop serves ~2022->current; older
# revisions reuse the last successfully parsed map (flagged in provenance).
#
# MAINTAINABILITY: keyed off the USITC release name, cached per revision, runs in
# the build. Mirrors download_chapter99_pdf_cached() in scrape_us_notes.R.
# =============================================================================
suppressWarnings(suppressMessages({
  library(here); library(dplyr); library(stringr); library(tibble); library(readr); library(purrr)
}))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

GN3_CACHE_DIR <- here::here('data', 'cache', 'general_notes')

# --- Fetch + cache the General Note PDF for a release ------------------------
fetch_general_note_pdf <- function(note_num, release_name = 'currentRelease',
                                   cache_dir = GN3_CACHE_DIR) {
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  safe_rel <- gsub('[^A-Za-z0-9]', '_', release_name)
  dest <- file.path(cache_dir, sprintf('GN%s_%s.pdf', note_num, safe_rel))
  if (file.exists(dest) && file.info(dest)$size > 1000) return(dest)
  url <- sprintf('https://hts.usitc.gov/reststop/file?release=%s&filename=General+Note+%s',
                 utils::URLencode(release_name, reserved = TRUE), note_num)
  ok <- tryCatch({ utils::download.file(url, dest, mode = 'wb', quiet = TRUE); TRUE },
                 error = function(e) FALSE)
  if (!ok || !file.exists(dest) || file.info(dest)$size <= 1000) return(NA_character_)
  dest
}

gn_pdf_to_text <- function(pdf_path) {
  if (is.na(pdf_path) || !file.exists(pdf_path)) return(NA_character_)
  txt <- tryCatch(system2('pdftotext', c('-layout', shQuote(pdf_path), '-'),
                          stdout = TRUE, stderr = FALSE),
                  error = function(e) NA_character_)
  if (length(txt) == 0 || all(is.na(txt))) return(NA_character_)
  paste(txt, collapse = '\n')
}

# Lines that are page-break / header noise, not data.
.gn_noise <- function(x) {
  str_detect(x, regex('Harmonized Tariff Schedule|Annotated for Statistical|^\\s*GN p\\.|General Note 3\\s*$|^\\s*\\d+/\\s|^\\s*$', ignore_case = TRUE))
}

# --- 3(b): Column 2 country list --------------------------------------------
parse_gn3_column2 <- function(text) {
  lines <- str_split(text, '\n')[[1]]
  start <- which(str_detect(lines, regex('Rate of Duty Column 2', ignore_case = TRUE)))[1]
  if (is.na(start)) return(tibble(country_name = character()))
  # The country list begins after the "...following countries and areas...:" lead
  # and ends at the "(c)" Products-Eligible heading.
  end <- which(str_detect(lines, regex('^\\s*\\(c\\)\\s', ignore_case = TRUE)) & seq_along(lines) > start)[1]
  if (is.na(end)) end <- min(start + 30L, length(lines))
  block <- lines[start:end]
  # Country names sit in a 2-column layout after the colon lead-in; capture lines
  # that are mostly title-case words and split on runs of 2+ spaces.
  cand <- block[str_detect(block, '^\\s{6,}[A-Z]') & !.gn_noise(block)]
  cand <- cand[!str_detect(cand, regex('countries and areas|pursuant to|section|President|Tariff', ignore_case = TRUE))]
  names <- cand %>% str_split('\\s{2,}') %>% unlist() %>% str_trim()
  names <- names[nzchar(names) & str_detect(names, '[A-Za-z]')]
  tibble(country_name = unique(names))
}

# --- 3(c)(i): Special-program symbol map ------------------------------------
parse_gn3_symbols <- function(text) {
  lines <- str_split(text, '\n')[[1]]
  start <- which(str_detect(lines, regex('the corresponding symbols for such programs', ignore_case = TRUE)))[1]
  if (is.na(start)) start <- which(str_detect(lines, regex('Programs under which special tariff treatment', ignore_case = TRUE)))[1]
  if (is.na(start)) return(tibble(symbol = character(), program_name = character()))
  end <- which(str_detect(lines, regex('^\\s*\\(ii\\)', ignore_case = TRUE)) & seq_along(lines) > start)[1]
  if (is.na(end)) end <- min(start + 60L, length(lines))
  block <- lines[(start + 1L):(end - 1L)]
  block <- block[!.gn_noise(block)]
  out <- list(); pending <- ''
  # Each entry: "Program name .... SYMBOL[, SYMBOL or SYMBOL]". Names can wrap onto
  # a prior line with no trailing dotted symbol -> accumulate into `pending`.
  m <- str_match(block, '^\\s*(.*?)\\.{3,}\\s*([A-Za-z][A-Za-z0-9*+,\\s]*?)\\s*$')
  for (i in seq_len(nrow(m))) {
    if (is.na(m[i, 1])) {                       # no dotted symbol -> continuation
      frag <- str_trim(block[i]); if (nzchar(frag)) pending <- str_trim(paste(pending, frag)); next
    }
    name <- str_trim(paste(pending, str_trim(m[i, 2]))); pending <- ''
    # Strip any sentence lead-in that wrapped into the first entry's name.
    name <- str_replace(name, regex('.*as follows:\\s*', ignore_case = TRUE), '')
    sym_raw <- str_trim(m[i, 3])
    syms <- sym_raw %>% str_replace_all('\\bor\\b', ',') %>% str_split(',') %>% unlist() %>% str_trim()
    syms <- syms[nzchar(syms) & str_detect(syms, '^[A-Z][A-Z]?[*+]?$')]
    for (s in syms) out[[length(out) + 1L]] <- tibble(symbol = s, program_name = name)
  }
  if (length(out) == 0) return(tibble(symbol = character(), program_name = character()))
  bind_rows(out) %>% distinct(symbol, .keep_all = TRUE)
}

# --- Build for one revision (returns parsed tables + provenance) -------------
build_gn3_for_revision <- function(revision, release_name) {
  pdf <- fetch_general_note_pdf('3', release_name)
  txt <- gn_pdf_to_text(pdf)
  if (is.na(txt)) return(NULL)
  list(
    revision = revision,
    column2  = parse_gn3_column2(txt) %>% mutate(revision = revision,
                 source_url = sprintf('reststop General+Note+3 @ %s', release_name)),
    symbols  = parse_gn3_symbols(txt) %>% mutate(revision = revision,
                 source_url = sprintf('reststop General+Note+3 @ %s', release_name)),
    source_hash = digest_or_na(pdf)
  )
}

digest_or_na <- function(path) {
  if (is.na(path) || !file.exists(path)) return(NA_character_)
  tryCatch(as.character(tools::md5sum(path)), error = function(e) NA_character_)
}

# --- Emit resources/gn3_*.csv for a set of (revision -> release_name) pairs ---
# `releases` is a tibble(revision, release_name). Revisions whose GN3 fetch fails
# reuse the most-recent successfully-parsed map (carry-forward), flagged via
# fallback_from. Falls back to the current release for a one-shot run.
# Same revision -> USITC release-name mapping as extract_legal_refs.R (kept local
# so this module is sourceable on its own).
gn3_revision_to_release_name <- function(revision) {
  m <- regmatches(revision, regexec('^([0-9]{4})_(.*)$', revision))[[1]]
  if (length(m) == 3) { yr <- m[2]; rest <- m[3] } else { yr <- '2025'; rest <- revision }
  if (rest == 'basic') return(paste0(yr, 'HTSBasic'))
  paste0(yr, 'HTSRev', sub('^rev_', '', rest))
}

# INCREMENTAL: only fetch+parse revisions not already in the committed CSVs (so a
# newly-released revision triggers extraction of JUST that revision; everything
# else is reused). Mirrors emit_legal_refs_incremental(). `only` restricts to a
# subset; `force` re-extracts everything.
emit_gn3 <- function(only = NULL, force = FALSE, out_dir = here::here('resources')) {
  sym_path  <- file.path(out_dir, 'gn3_program_symbols.csv')
  col2_path <- file.path(out_dir, 'gn3_column2_countries.csv')

  rd <- suppressMessages(readr::read_csv(here::here('config', 'revision_dates.csv'),
                                         show_col_types = FALSE))
  if ('effective_date' %in% names(rd)) rd <- rd[order(rd$effective_date), ]  # oldest -> newest
  target <- rd$revision
  if (!is.null(only)) target <- target[target %in% only]

  ex_sym  <- if (file.exists(sym_path))  suppressMessages(readr::read_csv(sym_path,  show_col_types = FALSE)) else NULL
  ex_col2 <- if (file.exists(col2_path)) suppressMessages(readr::read_csv(col2_path, show_col_types = FALSE)) else NULL
  done <- if (!is.null(ex_sym)) unique(ex_sym$revision) else character(0)
  todo <- if (force) target else setdiff(target, done)
  if (length(todo) == 0) {
    message('GN3: all ', length(target), ' target revisions already extracted (force=TRUE to refresh)')
    return(invisible(NULL))
  }

  # Seed carry-forward from the most recent already-extracted revision.
  last_sym <- NULL; last_col2 <- NULL; last_rev <- NA_character_
  prior_done <- intersect(target, done)
  if (length(prior_done) > 0 && !is.null(ex_sym)) {
    last_rev  <- tail(prior_done, 1)
    last_sym  <- ex_sym  %>% filter(revision == last_rev) %>% select(symbol, program_name)
    last_col2 <- ex_col2 %>% filter(revision == last_rev) %>% select(country_name)
  }

  new_sym <- list(); new_col2 <- list()
  for (rev in todo) {
    res <- tryCatch(build_gn3_for_revision(rev, gn3_revision_to_release_name(rev)),
                    error = function(e) NULL)
    if (!is.null(res) && nrow(res$symbols) > 0) {
      new_sym[[rev]]  <- res$symbols %>% mutate(fallback_from = NA_character_)
      new_col2[[rev]] <- res$column2 %>% mutate(fallback_from = NA_character_)
      last_sym  <- res$symbols %>% select(symbol, program_name)
      last_col2 <- res$column2 %>% select(country_name)
      last_rev  <- rev
      message('  GN3 ', rev, ': ', nrow(res$symbols), ' symbols, ', nrow(res$column2), ' Column 2')
    } else if (!is.null(last_sym)) {                    # reststop gap -> carry forward
      url <- sprintf('carried_forward_from %s', last_rev)
      new_sym[[rev]]  <- last_sym  %>% mutate(revision = rev, source_url = url, fallback_from = last_rev)
      new_col2[[rev]] <- last_col2 %>% mutate(revision = rev, source_url = url, fallback_from = last_rev)
      message('  GN3 ', rev, ': no PDF served -> carried forward from ', last_rev)
    } else {
      message('  GN3 ', rev, ': no PDF and no prior map (pre-2022 reststop gap) -> skipped')
    }
  }

  sym  <- bind_rows(ex_sym,  bind_rows(new_sym))  %>% distinct(revision, symbol, .keep_all = TRUE)
  col2 <- bind_rows(ex_col2, bind_rows(new_col2)) %>% distinct(revision, country_name, .keep_all = TRUE)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(sym,  sym_path)
  readr::write_csv(col2, col2_path)
  message('GN3: +', length(todo), ' revision(s); CSV now ', length(unique(sym$revision)),
          ' revisions / ', nrow(sym), ' symbol rows, ', nrow(col2), ' Column 2 rows')
  invisible(list(symbols = sym, column2 = col2))
}

# =============================================================================
# Beneficiary-country lists (de-hardcode GSP / AGOA / CBI / FTA partner maps)
# =============================================================================
# Generalized "country list in a GN section" extractor. Preference programs whose
# eligibility is a COUNTRY LIST (GSP GN 4, AGOA GN 16, CBERA/CBI GN 7) and the FTA
# partner notes all share the same -layout structure: a "...are designated...:"
# lead-in, then a multi-column block of country names (with wraps + footnotes).
#
# A tiny per-program config (GN_PROGRAM_GEO) supplies only the LOCATION (which GN +
# anchor phrase) and the HTS symbol — never the country VALUES. Country names are
# pulled live from the GN and mapped to census codes; precision-first: a name that
# does not match EXACTLY (or via a reviewed alias) is emitted name-only with no
# census_code, so the frontend never asserts a false beneficiary -> never a bogus
# preference (a miss just falls back to the safe base-NTR/MFN default).
# =============================================================================

# --- normalize a country name to a match key --------------------------------
# accents->ASCII, lower, drop parentheticals/footnotes/punct, st->saint, &->and,
# then strip government-form words that don't disambiguate. Collisions that this
# would create (e.g. both Congos -> "congo") are dropped by the ambiguity guard in
# .load_census_lut(), so over-stripping is SAFE (it yields "unmatched", never a
# wrong code).
.GOV_WORDS <- paste0('\\b(republic|democratic|peoples?|kingdom|federal|union|islamic|',
                     'arab|commonwealth|principality|sultanate|cooperative|bolivarian|',
                     'plurinational|socialist|independent|gabonese|of|the|and)\\b')
.norm_country <- function(x) {
  if (is.na(x)) return(NA_character_)
  x <- stringi::stri_trans_general(x, 'Latin-ASCII')
  x <- tolower(x)
  x <- stringr::str_replace_all(x, '\\([^)]*\\)', ' ')      # drop "(Republic of Moldova)"
  x <- stringr::str_replace_all(x, '\\d+\\s*/', ' ')        # drop footnote "1/"
  x <- stringr::str_replace_all(x, '&', ' and ')
  x <- stringr::str_replace_all(x, '[^a-z ]', ' ')          # punctuation -> space
  x <- stringr::str_replace_all(x, '\\bst\\b', 'saint')
  x <- stringr::str_replace_all(x, .GOV_WORDS, ' ')
  x <- stringr::str_replace_all(x, '\\s+', ' ')
  stringr::str_trim(x)
}

# LIGHT normalizer for the ALIAS layer: keeps every substantive word (incl. paren
# content and govt-form words) so distinct long-forms stay distinct — the four
# Congo variants map to "congo brazzaville" / "congo kinshasa" / "republic of congo"
# / "democratic republic of the congo", never colliding. Aliases are matched with
# this so a reviewed "Democratic Republic of the Congo -> 7660" can't leak to 7630.
.norm_light <- function(x) {
  if (is.na(x)) return(NA_character_)
  x <- stringi::stri_trans_general(x, 'Latin-ASCII')
  x <- tolower(x)
  x <- stringr::str_replace_all(x, '\\d+\\s*/', ' ')        # footnotes
  x <- stringr::str_replace_all(x, '&', ' and ')
  x <- stringr::str_replace_all(x, '[^a-z ]', ' ')          # strips ( ) , . ' but keeps inner words
  x <- stringr::str_replace_all(x, '\\bst\\b', 'saint')
  x <- stringr::str_replace_all(x, '\\s+', ' ')
  stringr::str_trim(x)
}

# --- census lookups: aggressive auto-match + light-keyed reviewed alias layer ---
.LUTS <- NULL
.load_luts <- function(force = FALSE) {
  if (!is.null(.LUTS) && !force) return(.LUTS)
  cz <- suppressMessages(readr::read_csv(here::here('resources', 'census_codes.csv'),
                                         show_col_types = FALSE))
  mk <- function(nm, code) {
    short_p <- stringr::str_replace(nm, '\\(.*$', '')        # before "("
    short_c <- stringr::str_replace(nm, ',.*$', '')          # before ","
    tibble(key = unique(c(.norm_country(nm), .norm_country(short_p), .norm_country(short_c))),
           code = as.character(code), name = nm)
  }
  keys <- bind_rows(Map(mk, cz$Name, cz$Code)) %>% filter(nzchar(key))
  amb  <- keys %>% count(key) %>% filter(n > 1) %>% pull(key)   # a key for 2+ codes is unsafe -> drop
  census <- keys %>% filter(!key %in% amb) %>% distinct(key, .keep_all = TRUE)
  # Reviewed aliases (resources/country_name_aliases.csv: gn_name, census_code[, note]).
  # Individually-verifiable spelling/long-form variants (Cape Verde -> Cabo Verde,
  # the named Congos, Gabonese Republic -> Gabon). Same category as census_codes.csv;
  # matched with .norm_light so disambiguating tokens are preserved.
  alias <- tibble(key = character(), code = character(), name = character())
  apath <- here::here('resources', 'country_name_aliases.csv')
  if (file.exists(apath)) {
    al <- suppressMessages(readr::read_csv(apath, show_col_types = FALSE))
    if (all(c('gn_name', 'census_code') %in% names(al))) {
      cz_name <- setNames(cz$Name, as.character(cz$Code))
      alias <- tibble(key = vapply(al$gn_name, .norm_light, ''),
                      code = as.character(al$census_code)) %>%
               mutate(name = unname(cz_name[code])) %>%
               filter(nzchar(key) & !is.na(name)) %>%
               distinct(key, .keep_all = TRUE)
    }
  }
  .LUTS <<- list(census = census, alias = alias)
  .LUTS
}

# names -> tibble(country_name, census_code, census_name, match_status). Tries the
# aggressive census key first (clean single-word majority), then the light alias
# key. A name matching neither is 'unmatched' with census_code = NA (no eligibility
# asserted) — precision over recall, so a miss is a safe false-negative, never a
# fabricated beneficiary.
match_countries_to_census <- function(names) {
  if (length(names) == 0) return(tibble(country_name = character(), census_code = character(),
                                         census_name = character(), match_status = character()))
  L  <- .load_luts()
  ka <- vapply(names, .norm_country, ''); ia <- match(ka, L$census$key)
  kl <- vapply(names, .norm_light,   ''); il <- match(kl, L$alias$key)
  use_alias <- is.na(ia) & !is.na(il)
  tibble(
    country_name = names,
    census_code  = ifelse(!is.na(ia), L$census$code[ia], ifelse(use_alias, L$alias$code[il], NA_character_)),
    census_name  = ifelse(!is.na(ia), L$census$name[ia], ifelse(use_alias, L$alias$name[il], NA_character_)),
    match_status = ifelse(!is.na(ia), 'matched', ifelse(use_alias, 'alias', 'unmatched'))
  )
}

# --- split a -layout line into (start_offset, text) column cells -------------
.split_cells <- function(ln) {
  first <- stringr::str_locate(ln, '\\S')[1, 'start']
  if (is.na(first)) return(NULL)
  gaps <- stringr::str_locate_all(ln, '\\s{2,}')[[1]]
  if (nrow(gaps)) gaps <- gaps[gaps[, 'start'] > first, , drop = FALSE]   # ignore leading indent
  if (nrow(gaps) == 0)
    return(tibble(start = first, text = stringr::str_trim(substring(ln, first, nchar(ln)))))
  starts <- c(first, gaps[, 'end'] + 1)
  ends   <- c(gaps[, 'start'] - 1, nchar(ln))
  tibble(start = starts, text = stringr::str_trim(substring(ln, starts, ends))) %>% filter(nzchar(text))
}

# --- extract a country list block, column-aware, rejoining wrapped names -----
.gn_list_prose <- paste0('pursuant|section|U\\.S\\.C|provided for|treatment|purpose|',
  'Non-Independent|territor|instruction|information|potential|retroactive|symbol|',
  'subdivision|Trade Act|having been|requirement|enumerated|shall be|imported|',
  'appraised|percent|beneficiar|developed|associations|eligible|designated|following|note|',
  # GSP "associations of countries eligible as one country" group headers (not countries)
  'Member |Consisting|qualifying|Cartagena|Andean|Monetary|Common Market|Regional Cooperation|',
  'Asian Association|Asian Nations|Community|Association of|Economic and')
parse_gn_country_list <- function(text, anchor) {
  if (is.na(text)) return(tibble(country_name = character()))
  L <- stringr::str_split(text, '\n')[[1]]
  s <- which(stringr::str_detect(L, regex(anchor, ignore_case = TRUE)))[1]
  if (is.na(s)) return(tibble(country_name = character()))
  lead_end <- s                                              # list starts after the ":" lead-in
  for (k in s:min(s + 4L, length(L))) if (stringr::str_detect(L[k], ':\\s*$')) { lead_end <- k; break }
  e <- which(stringr::str_detect(L, '^\\s*\\([b-z]\\)') & seq_along(L) > lead_end)[1]
  if (is.na(e)) e <- min(lead_end + 120L, length(L))
  blk <- L[(lead_end + 1L):(e - 1L)]
  keep <- stringr::str_detect(blk, '[A-Za-z]') & !.gn_noise(blk) &
          !stringr::str_detect(blk, regex(.gn_list_prose, ignore_case = TRUE)) &
          !stringr::str_detect(blk, regex('^\\s*Independent Countries\\s*$', ignore_case = TRUE))
  C <- list(); ln_seq <- 0L
  for (j in which(keep)) {
    cs <- .split_cells(blk[j]); if (is.null(cs) || nrow(cs) == 0) next
    ln_seq <- ln_seq + 1L; cs$line <- ln_seq; C[[length(C) + 1L]] <- cs
  }
  if (length(C) == 0) return(tibble(country_name = character()))
  C <- bind_rows(C)
  C <- C[stringr::str_detect(C$text, '[A-Za-z]{2,}') & C$text != 'null', , drop = FALSE]
  if (nrow(C) == 0) return(tibble(country_name = character()))
  # cluster cell start-offsets into columns (within ~4 chars), preserve line order
  us <- sort(unique(C$start)); col_of <- integer(length(us)); cc <- 0L; last <- -100L
  for (i in seq_along(us)) { if (us[i] - last > 4L) cc <- cc + 1L; col_of[i] <- cc; last <- us[i] }
  C$col <- col_of[match(C$start, us)]
  out <- character()
  for (cl in sort(unique(C$col))) {                          # rejoin wraps down each column
    sub <- C[C$col == cl, ]; sub <- sub[order(sub$line), ]; cur <- ''
    for (i in seq_len(nrow(sub))) {
      t <- stringr::str_trim(stringr::str_replace(sub$text[i], '\\s*\\d+\\s*/\\s*$', ''))
      cont <- nzchar(cur) && (
        stringr::str_detect(cur, '(\\b(and|the|of)\\b|[,&])\\s*$') ||   # dangling connector
        (stringr::str_count(cur, '\\(') > stringr::str_count(cur, '\\)')) ||  # open paren
        stringr::str_detect(t, '^[a-z(]'))                                # continues lowercase/paren
      if (cont) cur <- stringr::str_trim(paste(cur, t))
      else { if (nzchar(cur)) out <- c(out, cur); cur <- t }
    }
    if (nzchar(cur)) out <- c(out, cur)
  }
  out <- stringr::str_trim(stringr::str_replace_all(out, '\\s+', ' '))
  out <- out[nzchar(out) & stringr::str_detect(out, '[A-Za-z]{2,}')]
  tibble(country_name = unique(out))
}

# --- per-program LOCATION config (symbol + GN + anchor phrase; NO country values) ---
GN_PROGRAM_GEO <- tibble::tribble(
  ~symbol, ~program,       ~gn,  ~anchor,
  'A',     'GSP',          '4',  'are designated beneficiary developing countr',
  'D',     'AGOA',         '16', 'are to be afforded',
  'E',     'CBERA (CBI)',  '7',  'are designated beneficiary countr'
)

# Build all program beneficiary rows for one revision.
build_gn_program_countries_for_revision <- function(revision, release_name) {
  rows <- list()
  for (i in seq_len(nrow(GN_PROGRAM_GEO))) {
    g   <- GN_PROGRAM_GEO[i, ]
    pdf <- fetch_general_note_pdf(g$gn, release_name)
    txt <- gn_pdf_to_text(pdf)
    if (is.na(txt)) next
    names <- parse_gn_country_list(txt, g$anchor)$country_name
    if (length(names) == 0) next
    m <- match_countries_to_census(names)
    rows[[length(rows) + 1L]] <- m %>% mutate(
      revision = revision, symbol = g$symbol, program = g$program, general_note = g$gn,
      source_url = sprintf('reststop General+Note+%s @ %s', g$gn, release_name),
      source_hash = digest_or_na(pdf))
  }
  if (length(rows) == 0) return(NULL)
  bind_rows(rows)
}

# INCREMENTAL emit -> resources/gn_program_countries.csv (same pattern as emit_gn3).
emit_gn_program_countries <- function(only = NULL, force = FALSE,
                                      out_dir = here::here('resources')) {
  out_path <- file.path(out_dir, 'gn_program_countries.csv')
  rd <- suppressMessages(readr::read_csv(here::here('config', 'revision_dates.csv'),
                                         show_col_types = FALSE))
  if ('effective_date' %in% names(rd)) rd <- rd[order(rd$effective_date), ]
  target <- rd$revision
  if (!is.null(only)) target <- target[target %in% only]

  ex <- if (file.exists(out_path)) suppressMessages(readr::read_csv(out_path, show_col_types = FALSE)) else NULL
  done <- if (!is.null(ex)) unique(ex$revision) else character(0)
  todo <- if (force) target else setdiff(target, done)
  if (length(todo) == 0) {
    message('GN beneficiaries: all ', length(target), ' revisions already extracted (force=TRUE to refresh)')
    return(invisible(NULL))
  }
  # carry-forward seed from the most recent already-extracted revision
  last_rev <- NA_character_; last_rows <- NULL
  prior_done <- intersect(target, done)
  if (length(prior_done) > 0 && !is.null(ex)) {
    last_rev  <- tail(prior_done, 1)
    last_rows <- ex %>% filter(revision == last_rev) %>%
                 select(country_name, census_code, census_name, match_status, symbol, program, general_note)
  }
  new_rows <- list()
  for (rev in todo) {
    res <- tryCatch(build_gn_program_countries_for_revision(rev, gn3_revision_to_release_name(rev)),
                    error = function(e) NULL)
    if (!is.null(res) && nrow(res) > 0) {
      new_rows[[rev]] <- res %>% mutate(fallback_from = NA_character_)
      last_rev  <- rev
      last_rows <- res %>% select(country_name, census_code, census_name, match_status, symbol, program, general_note)
      matched <- sum(res$match_status %in% c('matched', 'alias'))
      message('  GN benef ', rev, ': ', nrow(res), ' names across ', dplyr::n_distinct(res$program),
              ' programs, ', matched, ' mapped to census')
    } else if (!is.null(last_rows)) {
      new_rows[[rev]] <- last_rows %>% mutate(revision = rev,
        source_url = sprintf('carried_forward_from %s', last_rev),
        source_hash = NA_character_, fallback_from = last_rev)
      message('  GN benef ', rev, ': no PDF served -> carried forward from ', last_rev)
    } else {
      message('  GN benef ', rev, ': no PDF and no prior map -> skipped')
    }
  }
  all <- bind_rows(ex, bind_rows(new_rows)) %>% distinct(revision, symbol, country_name, .keep_all = TRUE)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(all, out_path)
  message('GN beneficiaries: +', length(todo), ' revision(s); CSV now ',
          dplyr::n_distinct(all$revision), ' revisions / ', nrow(all), ' rows')
  invisible(all)
}

# Direct run: Rscript src/parse_general_note_3.R  (incremental)
if (sys.nframe() == 0) { emit_gn3(); emit_gn_program_countries() }
