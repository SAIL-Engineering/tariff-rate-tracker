# =============================================================================
# parse_note_rules.R — extract the STACKING GRAMMAR from the Chapter 99 US Notes
# =============================================================================
#
# WHY THIS EXISTS
#
# The interaction rules between duty programs — which duty excludes which, on
# the whole article or only on a content share, which replaces the base rate,
# which stacks — live in the US Notes to Chapter 99. Until now they reached the
# pipeline by a human reading a passage and hand-coding the conclusion.
#
# That does not scale and does not stay current. Measured on ONE revision
# (2025_rev_20, 48,614 lines):
#
#     "shall not apply to"                          110
#     "in addition to"                               82
#     "Except as provided"                           55
#     "shall be subject to"                          41
#     "in lieu of"                                   35
#     "shall continue to be imposed"                 15
#     "provides the ordinary customs duty treatment"   8
#
# ~350 rule-bearing statements, in each of 95 revisions. Hand-reading samples a
# fraction of one revision and silently misses the rest — which is exactly how
# the pipeline ended up applying content-level scaling to programs the notes
# exclude at the ARTICLE level.
#
# So parse the grammar. It is regular:
#
#   "The additional duties imposed by heading(s) X shall not apply to Y"
#       -> exclusion(imposing = X, excluded = Y)
#   "... but such additional duties shall apply to the non-Z content"
#       -> the exclusion is CONTENT-level in Z, not article-level
#   "Except as provided for in heading X, heading Y provides the ordinary
#    customs duty treatment"                  -> default(Y) with exception(X)
#   "shall be collected in addition to"       -> stacks
#   "in lieu of"                              -> replaces the base rate
#
# COVERAGE IS THE POINT
#
# Every statement carrying a rule keyword but matching no pattern is reported as
# UNPARSED. A rule we cannot read is a rule we are not applying, and that must
# be visible rather than assumed away. Never report a coverage figure without
# the unparsed count beside it.
#
# Every extracted rule keeps its VERBATIM source text and note reference, so any
# rule the pipeline applies can be audited back to the sentence that created it.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
})

#' Flatten PDF-extracted note text into sentences
#'
#' The notes wrap mid-sentence with deep indentation, so line-based matching
#' misses most statements. Collapse whitespace first, then split on sentence
#' boundaries that precede a capital or a subdivision marker.
flatten_note_text <- function(txt) {
  flat <- gsub('\\s*\\n\\s*', ' ', txt)
  gsub('[[:space:]]+', ' ', flat)
}

.RULE_KEYWORDS <- c(
  'shall not apply to', 'in addition to', 'in lieu of', 'Except as provided',
  'provides the ordinary customs duty treatment', 'shall be subject to',
  'shall continue to be imposed'
)

#' Extract the exclusion grammar
#'
#' @param flat Flattened note text
#' @return tibble(relation, imposing_headings, target_headings, content_metal,
#'   scope, verbatim)
extract_exclusions <- function(flat) {
  pat <- paste0(
    'additional duties imposed by heading[s]?\\s+([0-9., –\\-]+?(?:and\\s+[0-9.\\-]+)?)\\s+',
    'shall not apply to\\s+(.{10,500}?)(?=\\.\\s+[A-Z(]|$)')
  m <- gregexpr(pat, flat, perl = TRUE, ignore.case = TRUE)
  hits <- regmatches(flat, m)[[1]]
  if (length(hits) == 0) return(tibble())

  map_dfr(hits, function(h) {
    g <- regmatches(h, regexec(pat, h, perl = TRUE, ignore.case = TRUE))[[1]]
    if (length(g) < 3) return(tibble())
    obj <- g[3]
    # "but such additional duties shall apply to the non-STEEL content" makes the
    # exclusion content-level. Its ABSENCE makes it article-level — that is the
    # distinction, and it is load-bearing.
    cm <- regmatches(obj, regexec('shall apply to the non-?([a-z]+)\\s*content',
                                  obj, ignore.case = TRUE))[[1]]
    tibble(
      relation          = 'excludes',
      imposing_headings = trimws(gsub(',\\s*and\\s*$|,\\s*$', '', g[2])),
      target_headings   = paste(unique(unlist(
                            regmatches(obj, gregexpr('9903\\.\\d{2}\\.\\d{2}', obj)))),
                            collapse = ';'),
      content_metal     = if (length(cm) >= 2) tolower(cm[2]) else NA_character_,
      scope             = if (length(cm) >= 2) 'content' else 'article',
      verbatim          = trimws(substr(h, 1, 600))
    )
  })
}

#' Extract "ordinary customs duty treatment" defaults and their exceptions
#'
#' Note 33(f) is the shape: "Except as provided for in heading 9903.94.06 and
#' 9903.94.32, heading 9903.94.05 provides the ordinary customs duty treatment
#' applicable to all entries of automobile parts". The DEFAULT heading carries
#' no additional duty; the exceptions carry it. Reading this backwards is how
#' auto parts came to be filed under a vehicles heading.
extract_ordinary_treatment <- function(flat) {
  pat <- paste0('Except as provided for in heading[s]?\\s+([0-9., and\\-]+?),\\s*',
                'heading\\s+(9903\\.\\d{2}\\.\\d{2})\\s+provides the ordinary customs duty ',
                'treatment\\s+(.{0,300}?)(?=\\.\\s+[A-Z(]|$)')
  m <- gregexpr(pat, flat, perl = TRUE, ignore.case = TRUE)
  hits <- regmatches(flat, m)[[1]]
  if (length(hits) == 0) return(tibble())
  map_dfr(hits, function(h) {
    g <- regmatches(h, regexec(pat, h, perl = TRUE, ignore.case = TRUE))[[1]]
    if (length(g) < 4) return(tibble())
    tibble(
      relation          = 'ordinary_treatment_default',
      imposing_headings = trimws(g[3]),                      # the DEFAULT heading
      target_headings   = paste(unique(unlist(
                            regmatches(g[2], gregexpr('9903\\.\\d{2}\\.\\d{2}', g[2])))),
                            collapse = ';'),                 # the EXCEPTIONS
      content_metal     = NA_character_,
      scope             = 'article',
      verbatim          = trimws(substr(h, 1, 600))
    )
  })
}

#' Extract the COUNTRY-SCOPE grammar with its carve-outs
#'
#' The largest unparsed category on the first pass, and the most fundamental:
#' it says which heading covers which country's products, and which headings are
#' carved out of it. Shape:
#'
#'   "For the purposes of heading 9903.01.01, products of Mexico, other than
#'    products described in headings 9903.01.02, 9903.01.03, 9903.01.04 or
#'    9903.01.05 and other than products for personal use ..."
#'
#' This matters beyond stacking. `03_parse_chapter99.R` currently infers country
#' scope from the tariff-line DESCRIPTION; the notes carry it authoritatively,
#' with the exclusions attached. The build reports 38,423 unknown-scope entries
#' and drops 18 of 20 §201 safeguard headings fail-closed because scope did not
#' parse — this is the text that resolves them.
extract_country_scope <- function(flat) {
  pat <- paste0(
    'For the purposes of heading[s]?\\s+(9903\\.\\d{2}\\.\\d{2})\\s*,\\s*',
    'products of\\s+([A-Z][A-Za-z ]{2,40}?)\\s*,?\\s*',
    '(other than\\s+.{0,400}?)?(?=\\.\\s+[A-Z(]|$)')
  m <- gregexpr(pat, flat, perl = TRUE)
  hits <- regmatches(flat, m)[[1]]
  if (length(hits) == 0) return(tibble())
  map_dfr(hits, function(h) {
    g <- regmatches(h, regexec(pat, h, perl = TRUE))[[1]]
    if (length(g) < 3) return(tibble())
    carve <- if (length(g) >= 4 && !is.na(g[4])) g[4] else ''
    tibble(
      relation          = 'covers_country',
      imposing_headings = g[2],
      target_headings   = paste(unique(unlist(
                            regmatches(carve, gregexpr('9903\\.\\d{2}\\.\\d{2}', carve)))),
                            collapse = ';'),   # the CARVE-OUTS
      content_metal     = NA_character_,
      scope             = 'article',
      country           = trimws(g[3]),
      verbatim          = trimws(substr(h, 1, 600))
    )
  })
}


#' Extract the positive-application grammar
#'
#' The mirror of `shall not apply to`: which goods ARE caught by a heading.
#'   "Products of Mexico that are eligible for special tariff treatment under
#'    general note 3(c)(i) ... shall be subject to the additional ad valorem
#'    rate of duty imposed by heading 9903.01.05."
#' Load-bearing because it settles whether an FTA-eligible good still owes the
#' Chapter 99 duty — the question `rate_special` and the USMCA branch turn on.
extract_subject_to <- function(flat) {
  pat <- paste0('(.{20,300}?)\\s+shall be subject to the additional\\s+',
                '(?:ad valorem\\s+)?rate[s]? of duty\\s+(?:imposed|provided for)\\s+',
                '(?:by|in)\\s+heading[s]?\\s+([0-9., and\\-]+?)(?=\\.\\s|$)')
  m <- gregexpr(pat, flat, perl = TRUE, ignore.case = TRUE)
  hits <- regmatches(flat, m)[[1]]
  if (length(hits) == 0) return(tibble())
  map_dfr(hits, function(h) {
    g <- regmatches(h, regexec(pat, h, perl = TRUE, ignore.case = TRUE))[[1]]
    if (length(g) < 4) return(tibble())
    tibble(
      relation          = 'applies_to',
      imposing_headings = paste(unique(unlist(
                            regmatches(g[4], gregexpr('9903\\.\\d{2}\\.\\d{2}', g[4])))),
                            collapse = ';'),
      target_headings   = NA_character_,
      content_metal     = NA_character_,
      scope             = 'article',
      subject           = trimws(substr(g[2], max(1, nchar(g[2]) - 160), nchar(g[2]))),
      verbatim          = trimws(substr(h, 1, 600))
    )
  })
}


#' Extract STAGED duty-rate schedules from the US notes
#'
#' Safeguard rates under §201 step down annually. The HTS Rates-of-Duty column
#' carries only the INITIAL rate, and the operative rate for a given entry date
#' lives in a note subdivision that the tariff line points at by footnote:
#'
#'   "See US note 17(d) for staged duty rates for 9903.45.01 ..."
#'   "See note 18(f) for staged duty rates for 9903.45.22 and 18(h) for 9903.45.25."
#'
#' The note then publishes the schedule verbatim:
#'
#'   If entered during the period from
#'   February 7, 2023 through February 6, 2024 ......... 14.5%
#'   February 7, 2024 through February 6, 2025 ......... 14.25%
#'   February 7, 2025 through February 6, 2026 ......... 14%
#'
#' WHY THIS MATTERS. Reading either of the other two sources gives a wrong rate:
#' the HTS column says 30% (the 2018 stage), and config/policy_params.yaml
#' hardcodes `section_201.solar_rate: 0.145` — the 2023-24 stage, two steps
#' stale, with a comment that misdates it as current. For an entry on
#' 2025-08-27 the correct rate is 14%. A staged rate encoded as a constant is
#' wrong every year nobody remembers to edit it; the schedule is published, so
#' read it.
#'
#' @param flat Flattened note text
#' @return tibble(ch99_codes, effective_from, effective_to, rate, note_ref, verbatim)
extract_staged_rates <- function(flat) {
  empty <- tibble(ch99_codes = character(), effective_from = as.Date(character()),
                  effective_to = as.Date(character()), rate = numeric(),
                  note_ref = character(), verbatim = character())

  # Anchor on the note subdivision's OWN preamble, which names the heading it
  # governs. Associating by the footnote pointer instead does not work: the
  # pointers live in the tariff-line footnote block (~line 36k) while the
  # schedules live in the notes (~line 15k), so "nearest preceding pointer"
  # silently attributes every schedule to the first one.
  pre <- paste0('[Ff]or\\s+purposes\\s+of\\s+(?:sub)?heading[s]?\\s+',
                '((?:9903\\.\\d{2}\\.\\d{2}[, and]*)+)[^.]{0,400}?',
                '(?:shall\\s+be\\s+as\\s+follows|as\\s+follows)')
  pm <- gregexpr(pre, flat, perl = TRUE)
  pre_pos <- as.integer(pm[[1]])
  pre_txt <- regmatches(flat, pm)[[1]]
  if (length(pre_txt) == 0 || pre_pos[1] == -1) return(empty)

  # The schedule itself: a period followed by a percentage, dot leaders between.
  sched <- paste0('If entered during the period from\\s+',
                  '([A-Z][a-z]+\\s+\\d{1,2},\\s*\\d{4})\\s+through\\s+',
                  '([A-Z][a-z]+\\s+\\d{1,2},\\s*\\d{4})\\s*[. ]*\\s*',
                  '([0-9]+(?:\\.[0-9]+)?)\\s*%')
  sm <- gregexpr(sched, flat, perl = TRUE)
  rows <- regmatches(flat, sm)[[1]]
  s_pos <- as.integer(sm[[1]])
  if (length(rows) == 0 || s_pos[1] == -1) return(empty)

  # Each schedule row belongs to the preamble it FOLLOWS most closely, and only
  # if no later preamble intervenes — a schedule before any preamble belongs to
  # none and is reported with NA rather than guessed.
  codes_for <- rep(NA_character_, length(rows))
  for (i in seq_along(rows)) {
    before <- which(pre_pos <= s_pos[i])
    if (length(before) == 0) next
    j <- before[length(before)]
    g <- regmatches(pre_txt[j], regexec(pre, pre_txt[j], perl = TRUE))[[1]]
    if (length(g) >= 2) {
      codes_for[i] <- paste(unique(unlist(
        regmatches(g[2], gregexpr('9903\\.\\d{2}\\.\\d{2}', g[2])))), collapse = ';')
    }
  }

  out <- map_dfr(seq_along(rows), function(i) {
    g <- regmatches(rows[i], regexec(sched, rows[i], perl = TRUE))[[1]]
    if (length(g) < 4) return(tibble())
    tibble(
      ch99_codes     = codes_for[i],
      effective_from = suppressWarnings(as.Date(g[2], format = '%B %d, %Y')),
      effective_to   = suppressWarnings(as.Date(g[3], format = '%B %d, %Y')),
      rate           = as.numeric(g[4]) / 100,
      note_ref       = NA_character_,
      verbatim       = trimws(gsub('[[:space:]]+', ' ', rows[i])))
  })
  if (nrow(out) == 0) return(empty)
  out %>% filter(!is.na(effective_from), !is.na(effective_to))
}


#' The staged rate in force for a heading on a date
#'
#' @param staged Output of extract_staged_rates()
#' @param ch99_code Heading
#' @param on_date Entry/revision date
#' @return list(rate, note_ref, verbatim) or NULL when no schedule governs
staged_rate_on <- function(staged, ch99_code, on_date) {
  if (is.null(staged) || nrow(staged) == 0) return(NULL)
  on_date <- as.Date(on_date)
  hit <- staged %>%
    filter(!is.na(ch99_codes), grepl(ch99_code, ch99_codes, fixed = TRUE),
           effective_from <= on_date, effective_to >= on_date)
  if (nrow(hit) == 0) return(NULL)
  list(rate = hit$rate[1], note_ref = hit$note_ref[1], verbatim = hit$verbatim[1])
}


#' Extract SUSPENSION and EXPIRY of Chapter 99 provisions
#'
#' A heading can sit in the schedule for decades after it stops being
#' collectible. The HTS keeps the line and the rate; the notes say it is dead.
#' Nothing in the pipeline reads that, so an expired provision is indistinguish-
#' able from a live one — the only thing preventing collection today is that the
#' country scope failed to parse, which is protection by accident.
#'
#' Three forms carry it, all mechanical:
#'
#'   SUSPENDED   "The following provisions have been suspended pursuant to
#'                executive action: subheading 9903.41.25, and subheadings
#'                9903.41.35 through 9903.41.45, inclusive."   (note 5)
#'
#'   EXPIRED     "No rate of duty provided for in such subheadings ... shall be
#'                imposed on any article ... after the close of September 25,
#'                2012."                                        (note 14(b))
#'
#'   COMPILER    "[Compiler's note: provision suspended. See 90 Fed. Reg.
#'                50729.]" — inline on the tariff line itself, already used by
#'                the IEEPA extractor for 9903.01.63 but nowhere generalised.
#'
#' Ranges matter: "9903.41.35 through 9903.41.45, inclusive" names three of the
#' 100% Japan retaliation headings without listing them, so a literal-code match
#' would silently miss them.
#'
#' @param flat Flattened note text
#' @return tibble(ch99_code, status, expires_after, source, verbatim)
extract_provision_status <- function(flat) {
  empty <- tibble(ch99_code = character(), status = character(),
                  expires_after = as.Date(character()),
                  source = character(), verbatim = character())
  out <- list()

  # Expand "A through B, inclusive" plus any bare codes in a fragment.
  .codes_in <- function(txt) {
    codes <- character(0)
    rng <- gregexpr('(9903\\.\\d{2}\\.\\d{2})\\s+through\\s+(9903\\.\\d{2}\\.\\d{2})',
                    txt, perl = TRUE)
    for (m in regmatches(txt, rng)[[1]]) {
      g <- regmatches(m, regexec('(9903\\.\\d{2}\\.\\d{2})\\s+through\\s+(9903\\.\\d{2}\\.\\d{2})', m))[[1]]
      if (length(g) < 3) next
      a <- g[2]; b <- g[3]
      pa <- sub('^9903\\.', '', a); pb <- sub('^9903\\.', '', b)
      sa <- as.integer(sub('\\.', '', pa)); sb <- as.integer(sub('\\.', '', pb))
      sub_a <- substr(pa, 1, 2)
      if (!is.na(sa) && !is.na(sb) && sb >= sa && substr(pb, 1, 2) == sub_a) {
        # Chapter 99 numbers step in units within a subchapter pair.
        for (v in seq(sa, sb)) {
          codes <- c(codes, sprintf('9903.%s.%02d', sub_a, v %% 100))
        }
      }
      txt <- sub(m, ' ', txt, fixed = TRUE)
    }
    c(codes, unlist(regmatches(txt, gregexpr('9903\\.\\d{2}\\.\\d{2}', txt))))
  }

  # --- suspended -----------------------------------------------------------
  susp <- 'following provisions have been suspended[^:]*:\\s*(.{0,600}?)(?=\\.\\s+[A-Z0-9(]|$)'
  for (h in regmatches(flat, gregexpr(susp, flat, perl = TRUE, ignore.case = TRUE))[[1]]) {
    g <- regmatches(h, regexec(susp, h, perl = TRUE, ignore.case = TRUE))[[1]]
    if (length(g) < 2) next
    cds <- unique(.codes_in(g[2]))
    if (length(cds)) out[[length(out) + 1L]] <- tibble(
      ch99_code = cds, status = 'suspended', expires_after = as.Date(NA),
      source = 'note_suspension', verbatim = trimws(substr(h, 1, 400)))
  }

  # --- expired after a stated date -----------------------------------------
  # The date-bearing sentence names "such subheadings", so the codes come from
  # the enclosing subdivision preamble that introduced them.
  exp_pat <- paste0('([Ff]or\\s+the\\s+purposes\\s+of\\s+(?:sub)?heading[s]?\\s+',
                    '((?:9903\\.\\d{2}\\.\\d{2}[, and]*)+).{0,1200}?)',
                    'shall\\s+be\\s+imposed\\s+on\\s+any\\s+article[^.]{0,200}?',
                    'after\\s+the\\s+close\\s+of\\s+([A-Z][a-z]+\\s+\\d{1,2},\\s*\\d{4})')
  for (h in regmatches(flat, gregexpr(exp_pat, flat, perl = TRUE))[[1]]) {
    g <- regmatches(h, regexec(exp_pat, h, perl = TRUE))[[1]]
    if (length(g) < 4) next
    cds <- unique(unlist(regmatches(g[3], gregexpr('9903\\.\\d{2}\\.\\d{2}', g[3]))))
    d <- suppressWarnings(as.Date(g[4], format = '%B %d, %Y'))
    if (length(cds) && !is.na(d)) out[[length(out) + 1L]] <- tibble(
      ch99_code = cds, status = 'expired', expires_after = d,
      source = 'note_expiry',
      verbatim = trimws(gsub('[[:space:]]+', ' ', substr(h, nchar(h) - 180, nchar(h)))))
  }

  if (length(out) == 0) return(empty)
  bind_rows(out) %>% distinct(ch99_code, status, .keep_all = TRUE)
}


#' Suspension/termination stated inline on the tariff line
#'
#' Generalises the one-off check the IEEPA extractor already does for
#' 9903.01.63, so every authority gets it.
#'
#' @param description Tariff-line description
#' @return 'suspended', 'terminated', or NA
inline_provision_status <- function(description) {
  if (is.null(description) || is.na(description)) return(NA_character_)
  d <- tolower(description)
  if (grepl("compiler'?s note[^]]*terminated", d)) return('terminated')
  if (grepl("compiler'?s note[^]]*suspended", d))  return('suspended')
  NA_character_
}


#' Is a provision collectible on a date?
#'
#' @param status_tbl Output of extract_provision_status()
#' @param ch99_code Heading
#' @param on_date Entry/revision date
#' @return list(collectible, reason)
provision_collectible_on <- function(status_tbl, ch99_code, on_date) {
  if (is.null(status_tbl) || nrow(status_tbl) == 0)
    return(list(collectible = TRUE, reason = NA_character_))
  on_date <- as.Date(on_date)
  hit <- status_tbl[status_tbl$ch99_code == ch99_code, , drop = FALSE]
  if (nrow(hit) == 0) return(list(collectible = TRUE, reason = NA_character_))
  if (any(hit$status == 'suspended'))
    return(list(collectible = FALSE, reason = 'suspended_by_note'))
  ex <- hit[hit$status == 'expired' & !is.na(hit$expires_after), ]
  if (nrow(ex) > 0 && on_date > min(ex$expires_after))
    return(list(collectible = FALSE,
                reason = paste0('expired_after_', min(ex$expires_after))))
  list(collectible = TRUE, reason = NA_character_)
}


#' Statements that carry a rule keyword but matched no pattern
#'
#' This is the coverage gate. Report it beside any coverage figure — a rule we
#' cannot read is a rule we are not applying.
find_unparsed_rules <- function(flat, parsed_verbatim) {
  sentences <- unlist(strsplit(flat, '(?<=\\.)\\s+(?=[A-Z(])', perl = TRUE))
  has_kw <- vapply(sentences, function(s)
    any(vapply(.RULE_KEYWORDS, function(k) grepl(k, s, fixed = TRUE), logical(1))),
    logical(1))
  cand <- sentences[has_kw]
  if (length(parsed_verbatim) > 0) {
    covered <- vapply(cand, function(s) {
      any(vapply(parsed_verbatim, function(v)
        grepl(substr(v, 1, 60), s, fixed = TRUE), logical(1)))
    }, logical(1))
    cand <- cand[!covered]
  }
  tibble(verbatim = trimws(substr(cand, 1, 400)))
}

#' Parse all rules from one revision's Chapter 99 note PDF
#'
#' @param pdf_path Path to chapter99_<revision>.pdf
#' @param revision Revision id, stamped on every row
#' @return list(rules = tibble, unparsed = tibble, coverage = list)
parse_note_rules <- function(pdf_path, revision) {
  if (!file.exists(pdf_path)) stop('Note PDF not found: ', pdf_path, call. = FALSE)
  txt <- tryCatch(
    paste(system2('pdftotext', c('-layout', shQuote(pdf_path), '-'),
                  stdout = TRUE, stderr = FALSE), collapse = '\n'),
    error = function(e) stop('pdftotext failed on ', pdf_path, call. = FALSE))
  flat <- flatten_note_text(txt)

  rules <- bind_rows(
    extract_exclusions(flat),
    extract_ordinary_treatment(flat),
    extract_country_scope(flat),
    extract_subject_to(flat)
  )
  if (nrow(rules) > 0) rules$revision <- revision

  unparsed <- find_unparsed_rules(flat, if (nrow(rules)) rules$verbatim else character(0))
  if (nrow(unparsed) > 0) unparsed$revision <- revision

  kw_total <- sum(vapply(.RULE_KEYWORDS, function(k)
    lengths(gregexpr(k, flat, fixed = TRUE))[1], numeric(1)), na.rm = TRUE)

  list(
    rules = rules, unparsed = unparsed,
    coverage = list(revision = revision, parsed = nrow(rules),
                    unparsed = nrow(unparsed), keyword_hits = kw_total)
  )
}
