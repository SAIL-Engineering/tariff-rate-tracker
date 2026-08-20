# =============================================================================
# resolve_note_scope.R — the product scope that lives in the US Notes
# =============================================================================
#
# THE GAP THIS CLOSES
#
# resolve_product_scope.R reads scope stated ON the heading:
#   "provided for in subheading 8450.11.00 or 8450.20.00"
# That works for §201 safeguards. It does NOT work for §232 or IEEPA, whose
# headings state no products at all and instead point at a note subdivision:
#
#   9903.94.01  "...passenger vehicles ... as specified in note 33 ...,
#                as provided for in subdivision (b) of U.S. note 33"
#   9903.78.01  "Semi-finished copper ... provided for in subdivision (b) of
#                note 36"
#
# extract_covered_subheadings() correctly reports those as `by_note` rather
# than pretending they cover nothing — but nothing ever RESOLVED the pointer.
# The consequence is measurable: the attribution report can check the
# product-scope invariant on §201 (100% of its rows) and on essentially nothing
# else, because §232 and IEEPA headings have no readable scope. That is 99.9%
# of applied duty unchecked.
#
# WHERE THE SCOPE ACTUALLY IS
#
# The note subdivision enumerates the tariff lines in a plain block:
#
#   (b)  The rates of duty set forth in headings 9903.94.01, 9903.94.02, ...
#        apply to all imported products classifiable in the provisions of the
#        HTSUS enumerated in this subdivision:
#
#              8703.22.01   8703.23.01   8703.24.01
#              8703.31.01   8703.32.01   8703.33.01
#              ...
#              8704.21.01   8704.31.01   8704.41.00
#
# Read literally, note 33(b) contains NO 8708 line — 8708 is auto parts, whose
# scope is subdivision (g). So an 8708 row citing 9903.94.01 contradicts the
# published note, which is exactly the Class 2 defect, established here from the
# legal text rather than from a rate coincidence.
#
# WHAT THIS FILE DOES NOT DO
#
# It does not infer scope. If a subdivision enumerates no tariff lines — many
# are prose conditions ("upon approval from the Secretary of Commerce") — the
# result is an explicit `enumerates_none`, never an empty set silently treated
# as "covers everything" or "covers nothing".
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
})

# A tariff line in a note block: 4 digits, then 1-3 dotted 2-digit groups.
# Chapter 99 codes are matched by the same shape and separated afterwards,
# because a subdivision routinely cites BOTH ("headings 9903.94.01 ... apply to
# ... 8703.22.01"). Treating a 9903 cross-reference as covered product is the
# trap resolve_product_scope.R already documents.
.NOTE_HTS_PAT <- '\\b([0-9]{4}(?:\\.[0-9]{2}){1,3})\\b'


#' Split a note's text into its lettered subdivisions
#'
#' Subdivision markers are "(a)", "(b)" ... at the start of a block. Roman
#' numerals ("(i)", "(ii)", "(iii)") are NESTED items, not subdivisions, and
#' must not split their parent — subdivision (c) of note 33 contains (i) and
#' (ii), and splitting on them would truncate (c) at its first clause.
#'
#' @param note_text Text of a single note (already isolated)
#' @return named list: subdivision letter -> body text
split_note_subdivisions <- function(note_text) {
  if (is.null(note_text) || is.na(note_text) || !nzchar(note_text)) return(list())

  # Candidate markers, then drop roman numerals. 'i', 'v', 'x' are ambiguous —
  # they are valid subdivision letters AND roman numerals — so a marker is
  # treated as roman only when it is a multi-character roman string (ii, iii,
  # iv, vi ...). A bare "(i)" following "(h)" is subdivision i; a bare "(i)"
  # following "(ii)" would be nested, but that ordering does not occur.
  # A marker must not be a PROSE CROSS-REFERENCE. Subdivision (a) of note 33
  # says "enumerated in subdivision (b) of this note" long before the real (b)
  # marker appears, and a naive scan latches onto that first "(b)" — which put
  # subdivision (b)'s tariff lines under (c) and left (b) empty. Exclude
  # markers preceded by the words that introduce a reference.
  m <- gregexpr(paste0('(?<!subdivision )(?<!subdivisions )(?<!paragraph )',
                       '(?<!heading )(?<!headings )(?<!note )',
                       '\\(([a-z]{1,4})\\)'),
                note_text, perl = TRUE)[[1]]
  if (m[1] == -1) return(list())
  starts <- as.integer(m)
  lens   <- attr(m, 'match.length')
  labels <- vapply(seq_along(starts), function(i)
    substr(note_text, starts[i] + 1L, starts[i] + lens[i] - 2L), character(1))

  is_roman_nested <- nchar(labels) > 1 & grepl('^[ivx]+$', labels)
  keep <- !is_roman_nested
  if (!any(keep)) return(list())
  starts <- starts[keep]; lens <- lens[keep]; labels <- labels[keep]

  # Keep only a monotonically advancing a,b,c... sequence. A stray "(a)" inside
  # prose ("subdivision (a) of this note") must not start a new subdivision.
  ord <- match(labels, letters)
  keep2 <- rep(FALSE, length(labels))
  expect <- 1L
  for (i in seq_along(labels)) {
    if (!is.na(ord[i]) && ord[i] == expect) { keep2[i] <- TRUE; expect <- expect + 1L }
  }
  if (!any(keep2)) return(list())
  starts <- starts[keep2]; lens <- lens[keep2]; labels <- labels[keep2]

  ends <- c(starts[-1] - 1L, nchar(note_text))
  out <- lapply(seq_along(starts), function(i)
    substr(note_text, starts[i] + lens[i], ends[i]))
  names(out) <- labels
  out
}


#' Isolate one US note from the full Chapter 99 note text
#'
#' @param flat Flattened note text for the revision
#' @param note_num Note number (e.g. 33)
#' @return Character scalar, or NA if the note is absent from this revision
isolate_note <- function(flat, note_num) {
  if (is.null(flat) || !nzchar(flat)) return(NA_character_)
  # Notes are numbered "33." at a block start. Anchor on the number followed by
  # a period and a subdivision marker, which is how every note opens, so a bare
  # cross-reference ("U.S. note 33") does not match.
  pat <- sprintf('(?<![0-9])%d\\.\\s*\\(a\\)', note_num)
  st <- regexpr(pat, flat, perl = TRUE)
  if (st[1] == -1) return(NA_character_)
  nxt <- regexpr(sprintf('(?<![0-9])%d\\.\\s*\\(a\\)', note_num + 1L),
                 substring(flat, st[1] + 1L), perl = TRUE)
  en <- if (nxt[1] == -1) nchar(flat) else st[1] + nxt[1]
  substr(flat, st[1], en)
}


#' Tariff lines enumerated by one note subdivision
#'
#' @param flat Flattened note text for the revision
#' @param note_num Note number
#' @param subdiv Subdivision letter ('b')
#' @return list(prefixes, ch99_refs, status, n)
#'   status: 'enumerated' | 'enumerates_none' | 'subdivision_absent' |
#'           'note_absent'
note_subdivision_scope <- function(flat, note_num, subdiv) {
  none <- function(s) list(prefixes = character(0), ch99_refs = character(0),
                           status = s, n = 0L)
  nt <- isolate_note(flat, note_num)
  if (is.na(nt)) return(none('note_absent'))
  subs <- split_note_subdivisions(nt)
  if (!length(subs) || !subdiv %in% names(subs)) return(none('subdivision_absent'))

  body <- subs[[subdiv]]
  hits <- unlist(regmatches(body, gregexpr(.NOTE_HTS_PAT, body, perl = TRUE)))
  hits <- unique(trimws(hits))
  if (!length(hits)) return(none('enumerates_none'))

  is99 <- startsWith(hits, '99')
  pref <- gsub('\\.', '', hits[!is99])
  list(prefixes = pref, ch99_refs = hits[is99],
       status = if (length(pref)) 'enumerated' else 'enumerates_none',
       n = length(pref))
}


#' Resolve a heading's `by_note` pointer to real tariff lines
#'
#' Bridges resolve_product_scope.R: where extract_covered_subheadings() returns
#' status 'by_note' with a note_ref, this reads the note and returns the lines.
#'
#' @param description Chapter 99 heading description
#' @param flat Flattened note text for the revision
#' @return list(prefixes, status, note_num, subdiv)
heading_scope_via_note <- function(description, flat) {
  out <- list(prefixes = character(0), status = 'no_note_ref',
              note_num = NA_integer_, subdiv = NA_character_)
  if (is.null(description) || is.na(description) || !nzchar(description)) return(out)

  # "as provided for in subdivision (b) of U.S. note 33 to this subchapter"
  # "enumerated in subdivision (g) of note 33"
  m <- regmatches(description, regexec(
    paste0('subdivisions?\\s+\\(([a-z]{1,3})\\)(?:\\s*(?:and|,)\\s*\\(([a-z]{1,3})\\))?',
           '\\s+(?:of|to)\\s+(?:this\\s+)?(?:U\\.S\\.\\s*)?note\\s+([0-9]+)'),
    description, ignore.case = TRUE))[[1]]
  if (length(m) < 4) return(out)

  subs <- c(m[2], m[3]); subs <- subs[nzchar(subs)]
  nnum <- suppressWarnings(as.integer(m[4]))
  if (is.na(nnum)) return(out)

  pref <- character(0); st <- 'subdivision_absent'
  for (s in subs) {
    r <- note_subdivision_scope(flat, nnum, s)
    pref <- unique(c(pref, r$prefixes))
    if (r$status == 'enumerated') st <- 'enumerated'
    else if (st != 'enumerated') st <- r$status
  }
  list(prefixes = pref, status = st, note_num = nnum,
       subdiv = paste(subs, collapse = '+'))
}


#' Build the heading -> covered-tariff-line table for a revision
#'
#' Own-text scope wins; the note pointer is consulted only where the heading
#' states none. Both sources are reported so a heading covering nothing stays
#' visible rather than looking like a heading covering everything.
#'
#' @param ch99_data Parsed Chapter 99 table (ch99_code, description, rate)
#' @param flat Flattened note text for the revision
#' @return tibble(ch99_code, rate, scope_source, scope_status, n_prefixes,
#'   prefixes)
build_heading_scope <- function(ch99_data, flat) {
  stopifnot(all(c('ch99_code', 'description') %in% names(ch99_data)))
  have_own <- exists('extract_covered_subheadings', mode = 'function')

  map_dfr(seq_len(nrow(ch99_data)), function(i) {
    d <- ch99_data$description[i]
    own <- if (have_own) extract_covered_subheadings(d) else
      list(prefixes = character(0), status = 'none')
    if (length(own$prefixes) > 0) {
      return(tibble(ch99_code = ch99_data$ch99_code[i],
                    rate = ch99_data$rate[i] %||% NA_real_,
                    scope_source = 'own_text', scope_status = 'explicit',
                    n_prefixes = length(own$prefixes),
                    prefixes = list(own$prefixes)))
    }
    v <- heading_scope_via_note(d, flat)
    tibble(ch99_code = ch99_data$ch99_code[i],
           rate = ch99_data$rate[i] %||% NA_real_,
           scope_source = if (length(v$prefixes)) 'note' else 'unresolved',
           scope_status = v$status,
           n_prefixes = length(v$prefixes),
           prefixes = list(v$prefixes))
  })
}


#' Does a heading's scope cover an HTS10?
#'
#' @param prefixes Character vector of dotless prefixes
#' @param hts10 Character vector of HTS10 codes
#' @return Logical vector; NA where scope is unknown (never FALSE, because
#'   "we could not read the scope" is not "the scope excludes this")
scope_covers <- function(prefixes, hts10) {
  if (length(prefixes) == 0) return(rep(NA, length(hts10)))
  ok <- rep(FALSE, length(hts10))
  for (p in prefixes) ok <- ok | startsWith(hts10, p)
  ok
}
