# =============================================================================
# Step 04: Parse Product Data from HTS JSON
# =============================================================================
#
# Extracts HTS10 product data:
#   - Base MFN rate (from 'general' field)
#   - Special preferential rates and country eligibility codes (from 'special')
#   - Column 2 statutory rates (from 'other')
#   - Statistical reporting units (from 'units' — nonlegal per USITC preface)
#   - Rate basis classification (ad valorem, specific, compound)
#   - Duty basis unit (from the legal rate expression, NOT from reporting units)
#   - Chapter 99 footnote references
#
# Design note: In the U.S. HTSUS, the "Unit of Quantity" shown with a 10-digit
# statistical reporting number is required for customs entry documents but is NOT
# by itself the legal basis of duty. For ad valorem duties the calculation base
# is customs value; for specific duties it is the quantity in the legally
# specified unit (extracted from the rate text); for compound duties both are
# used. See 19 CFR 159.3 for rounding rules.
#
# Output: products_{revision}.rds with columns:
#   - hts10: 10-digit statistical reporting number
#   - description: Product description
#   - base_rate: MFN rate (numeric, ad valorem component)
#   - base_rate_raw: Original 'general' rate text
#   - rate_special: Primary special rate (numeric)
#   - rate_special_raw: Original special column text
#   - special_programs: List of parsed special sub-rate groups
#   - rate_column2: Column 2 rate (numeric, ad valorem component)
#   - rate_column2_raw: Original 'other' column text
#   - rate_basis: ad_valorem|specific|compound|free|unknown
#   - specific_amount: Dollar amount per unit (for specific/compound)
#   - specific_rate_unit: Unit from legal rate text (e.g., "kg", "pf.liter")
#   - reported_unit_1: First statistical reporting unit (nonlegal)
#   - reported_unit_2: Second statistical reporting unit (nonlegal)
#   - duty_basis_unit: Unit that drives duty math (= specific_rate_unit if
#       rate is specific/compound; NA otherwise)
#   - is_qty_duty_relevant: TRUE only for specific/compound rates
#   - quantity_source: Where duty_basis_unit came from (rate_text or NA)
#   - rounding_rule: 19 CFR 159.3 rule code
#   - calc_status: "ok" or "needs_manual_review" etc.
#   - ch99_refs: List of Chapter 99 references from footnotes
#   - has_complex_rate: Flag for non-ad-valorem rates
#
# =============================================================================

library(tidyverse)
library(jsonlite)

# NOTE: parse_rate(), is_simple_rate(), parse_rate_extended(),
# parse_special_programs_multi(), rate_type_label(), determine_rounding_rule(),
# normalize_hts(), is_valid_hts10(), and extract_chapter99_refs() are all
# defined in helpers.R. This file uses those shared versions.


# =============================================================================
# Main Parsing Function
# =============================================================================

#' Parse all products from HTS JSON
#'
#' @param json_path Path to HTS JSON file
#' @return Tibble with product data
parse_products <- function(json_path) {
  message('Reading HTS JSON from: ', json_path)

  # Read JSON
  hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
  message('  Total items: ', length(hts_raw))

  # Build inheritance stacks: for statistical suffixes (empty fields),
  # inherit rates from the nearest parent in the indent hierarchy.
  # ~59% of HTS10 products are statistical suffixes with empty general fields.
  #
  # Known edge case (rare): this assumes the JSON preserves parent-before-child
  # order and that indent levels increase monotonically within a heading. If
  # USITC changes the JSON structure (e.g., reorders items or introduces
  # non-standard indent jumps), inherited rates could be wrong. No validation
  # pass currently checks for these anomalies.
  rate_stack <- list()       # indent level -> parsed base_rate (numeric or NA)
  htsno_stack <- list()      # indent level -> htsno of the rate-bearing line (base_rate_source provenance)
  # general_raw_stack holds the nearest ancestor's rate TEXT, and
  # general_hts_stack the htsno that text came from. These two are pushed for
  # EVERY line with rate text, whereas rate_stack accepts only text that parses
  # as a simple percent or "Free". The two therefore name DIFFERENT ancestors
  # whenever a parent states a rate the simple parser cannot read, and a child
  # then took its NUMBER from one ancestor and its BASIS from another.
  #
  # Measured on 2025_rev_20: of the 437 inheriting rows typed 'unknown', the two
  # stacks disagreed on the parent in 437 — every single one. 275 were apparel
  # ensembles whose nearest parent reads "The rate applicable to each garment in
  # the ensemble if separately entered": rate_stack skipped that line and reached
  # past it, so lines under 6104.29.20 inherited the rate of 6104.19.80, an
  # unrelated garment class. That is a fabricated duty, not a labelling artefact.
  general_raw_stack <- list() # indent level -> general raw text
  general_hts_stack <- list() # indent level -> htsno that supplied that text
  special_stack <- list()    # indent level -> special raw text
  other_stack <- list()      # indent level -> other (Column 2) raw text
  unit1_stack <- list()      # indent level -> reported_unit_1 string
  unit2_stack <- list()      # indent level -> reported_unit_2 string
  n_inherited <- 0L

  # Helper to update an inheritance stack for a given indent level
  update_stack <- function(stack, indent, value) {
    stack[[as.character(indent)]] <- value
    deeper <- names(stack)[as.integer(names(stack)) > indent]
    for (d in deeper) stack[[d]] <- NULL
    stack
  }

  # Helper to inherit from nearest parent in a stack
  inherit_from_stack <- function(stack, indent) {
    for (i in seq(indent - 1, 0, by = -1)) {
      val <- stack[[as.character(i)]]
      if (!is.null(val)) return(val)
    }
    return(NULL)
  }

  # Process each item
  products <- map_dfr(hts_raw, function(item) {
    htsno <- item$htsno %||% ''
    general <- item$general %||% ''
    special_raw <- item$special %||% ''
    other_raw <- item$other %||% ''
    indent <- as.integer(item$indent %||% 0)
    # Statistical reporting units (nonlegal per USITC preface).
    # The HTS JSON 'units' array contains reporting units required on entry
    # documents. These do NOT by themselves drive duty calculation.
    # USITC encodes some units with HTML markup ("m<sup>2</sup>", "<u>kg</u>",
    # "Cr<sub>2</sub>O<sub>3</sub> t") inconsistently across revisions. Strip to
    # plain ASCII at the source so the value is identical revision-to-revision
    # and so the cleaned form (not the markup) feeds the inheritance stacks below.
    units_arr <- item$units %||% character(0)
    reported_unit_1 <- if (length(units_arr) >= 1) clean_reported_unit(units_arr[1]) else ''
    reported_unit_2 <- if (length(units_arr) >= 2) clean_reported_unit(units_arr[2]) else ''

    # Update rate stacks for any item with content (parents and products alike)
    parsed <- parse_rate(general)
    if (!is.na(parsed) || (is_simple_rate(general) || tolower(trimws(general)) == 'free')) {
      rate_stack[[as.character(indent)]] <<- parsed
      htsno_stack[[as.character(indent)]] <<- htsno
      deeper <- names(rate_stack)[as.integer(names(rate_stack)) > indent]
      for (d in deeper) { rate_stack[[d]] <<- NULL; htsno_stack[[d]] <<- NULL }
    }
    if (trimws(general) != '') {
      general_hts_stack <<- update_stack(general_hts_stack, indent, htsno)
      general_raw_stack <<- update_stack(general_raw_stack, indent, general)
    }
    if (trimws(special_raw) != '') {
      special_stack <<- update_stack(special_stack, indent, special_raw)
    }
    if (trimws(other_raw) != '') {
      other_stack <<- update_stack(other_stack, indent, other_raw)
    }
    if (reported_unit_1 != '') {
      unit1_stack <<- update_stack(unit1_stack, indent, reported_unit_1)
    }
    if (reported_unit_2 != '') {
      unit2_stack <<- update_stack(unit2_stack, indent, reported_unit_2)
    }

    # Keep 10-digit codes and 8-digit candidates. Some tariff lines are leaves
    # at 8 digits (no statistical suffix) — e.g., most of ch91 watches and ch98
    # special provisions (473 lines in upstream's 2026_rev_2 count). Census
    # reports these as HTS10 with a "00" suffix. Non-leaf 8-digit rows (those
    # with 10-digit statistical children) are dropped in the post-pass below.
    clean_code <- gsub('\\.', '', htsno)
    is_8digit_line <- nchar(clean_code) == 8 && grepl('^[0-9]+$', clean_code)
    if (!is_valid_hts10(htsno) && !is_8digit_line) {
      return(NULL)
    }

    # Skip Chapter 99 entries (they're not products)
    if (grepl('^99', htsno)) {
      return(NULL)
    }

    hts10 <- normalize_hts(htsno)  # pads 8-digit codes to 10 with "00"
    description <- item$description %||% ''

    # Parse general (MFN) rate — inherit from parent if empty. Record WHERE the
    # rate came from (own line / inherited:<parent_htsno> / unresolved) so the
    # rate-validation harness can assert every active line resolves to a base rate.
    base_rate <- parse_rate(general)
    has_complex <- !is_simple_rate(general) && general != ''
    base_rate_source <- if (trimws(general) != '') 'own' else NA_character_

    # parse_rate() returns NA for anything that is not a bare percent, which
    # silently drops the ad valorem HALF of every compound rate: "46.3c/kg +
    # 14.9%" became NA and then 0 downstream, losing a real 14.9% duty. 160 of
    # the 666 distinct Column 1 strings in 2026_rev_10 are recoverable this way.
    #
    # parse_duty_rate_string() recovers the article-level percent and names what
    # it could not represent, so the residual stays visible instead of becoming
    # an unmarked zero.
    base_rate_status <- NA_character_
    if (is.na(base_rate) && trimws(general) != '') {
      pr <- parse_duty_rate_string(general)
      base_rate_status <- pr$status
      if (!is.na(pr$ad_valorem)) {
        base_rate <- pr$ad_valorem
        base_rate_source <- paste0('own:', pr$status)
      }
    }

    # Inherit from the NEAREST ancestor that states a rate at all — then take the
    # number and the basis from THAT SAME ancestor.
    #
    # The previous version walked rate_stack, which holds only text that parses
    # as a simple percent or "Free". A parent stating a rate the simple parser
    # cannot read was therefore invisible to it, and the walk continued past that
    # parent to a more distant one. The child ended up with a rate belonging to a
    # different product group, while its basis was typed from the nearer parent —
    # two ancestors, one row.
    #
    # A parent that states a rate we cannot represent is NOT an absent parent. It
    # is a stated rule we have not resolved, and reaching past it invents a duty.
    # So stop at it and say so.
    inherited_general <- NULL
    inherited_from    <- NA_character_
    if (trimws(general) == '' && indent > 0) {
      for (i in seq(indent - 1, 0, by = -1)) {
        g <- general_raw_stack[[as.character(i)]]
        if (!is.null(g) && nzchar(trimws(g))) {
          inherited_general <- g
          inherited_from <- general_hts_stack[[as.character(i)]] %||% as.character(i)
          break
        }
      }
    }

    if (is.na(base_rate) && !is.null(inherited_general)) {
      pr_inh <- parse_rate(inherited_general)
      if (!is.na(pr_inh)) {
        base_rate <- pr_inh
        base_rate_source <- paste0('inherited:', inherited_from)
        n_inherited <<- n_inherited + 1L
      } else {
        # The nearest ancestor states something we cannot reduce to a single
        # article-level percent. Recover the ad valorem part if there is one, and
        # keep the named status either way so calc_status reports it honestly
        # instead of the row inheriting an unrelated ancestor's number.
        pd <- parse_duty_rate_string(inherited_general)
        base_rate_status <- pd$status
        # parse_duty_rate_string() reports ad_valorem = 0 for a purely SPECIFIC
        # duty ("4.4c/kg"), because there is no ad valorem component — 0 here
        # means "none", not "zero percent". Taking it as a recovered rate is the
        # NA-becomes-0 failure this file already warns about one screen down: it
        # replaced a rate with 0 on 624 rows in 2025_rev_20. The specific
        # component still reaches the row through general_for_type below, which
        # is where that duty actually lives.
        if (!is.na(pd$ad_valorem) && !identical(pd$status, 'specific_only')) {
          base_rate <- pd$ad_valorem
          base_rate_source <- paste0('inherited:', inherited_from, ':', pd$status)
          n_inherited <<- n_inherited + 1L
        } else {
          base_rate_source <- paste0('inherited_unrepresentable:', inherited_from,
                                     ':', pd$status)
        }
      }
    }
    if (is.na(base_rate_source)) base_rate_source <- 'unresolved'

    # Inherit special/other/units from parent if empty (statistical suffix)
    if (trimws(special_raw) == '' && indent > 0) {
      inherited <- inherit_from_stack(special_stack, indent)
      if (!is.null(inherited)) special_raw <- inherited
    }
    if (trimws(other_raw) == '' && indent > 0) {
      inherited <- inherit_from_stack(other_stack, indent)
      if (!is.null(inherited)) other_raw <- inherited
    }
    if (reported_unit_1 == '' && indent > 0) {
      inherited <- inherit_from_stack(unit1_stack, indent)
      if (!is.null(inherited)) reported_unit_1 <- inherited
    }
    if (reported_unit_2 == '' && indent > 0) {
      inherited <- inherit_from_stack(unit2_stack, indent)
      if (!is.null(inherited)) reported_unit_2 <- inherited
    }

    # Parse special column (all sub-rate groups)
    special_parsed <- parse_special_programs_multi(special_raw)
    # Primary special rate: first rate-type entry
    rate_special <- NA_real_
    if (length(special_parsed) > 0 && special_parsed[[1]]$entry_type == 'rate') {
      rate_special <- special_parsed[[1]]$rate
    }

    # Parse Column 2 (other) rate
    other_parsed <- parse_rate_extended(other_raw)
    rate_column2 <- if (!is.na(other_parsed$ad_valorem_pct)) other_parsed$ad_valorem_pct
                    else NA_real_

    # Parse general rate expression to determine rate basis and specific components.
    # The duty basis unit comes from the legal rate text (e.g., "kg" from
    # "30.5¢/kg + 8.5%"), NOT from the statistical reporting units.
    # For statistical suffixes with empty general, inherit from parent.
    # Reuse the ancestor resolved above rather than walking the stack a second
    # time. Walking twice is what let the number and the basis come from
    # different lines; there is now exactly one inherited ancestor per row.
    general_for_type <- if (trimws(general) == '' && !is.null(inherited_general)) {
      inherited_general
    } else {
      general
    }
    general_parsed <- parse_rate_extended(general_for_type)
    rate_basis <- general_parsed$type

    # Same disagreement as in calc_status below: where parse_rate_extended()
    # cannot type the string but parse_duty_rate_string() named it, take the
    # named answer. Only the three statuses that map cleanly onto the existing
    # rate_basis vocabulary are promoted — the others stay 'unknown' and are
    # distinguished by calc_status, so downstream consumers of rate_basis
    # (is_qty_duty_relevant, the schema) keep their five-value contract.
    if (identical(rate_basis, 'unknown') && !is.na(base_rate_status)) {
      rate_basis <- switch(base_rate_status,
        specific_only = 'specific',
        compound      = 'compound',
        free          = 'free',
        rate_basis)
    }
    specific_amount <- general_parsed$specific_amount
    # specific_rate_unit: the unit from the legal rate expression
    specific_rate_unit <- general_parsed$specific_rate_unit

    # Determine whether quantity is legally relevant for duty calculation.
    # Per 19 CFR 159.3 and CBP methodology: quantity enters the duty math
    # only when the applicable duty component is specific or compound.
    is_qty_duty_relevant <- rate_basis %in% c('specific', 'compound')

    # duty_basis_unit: the unit that drives duty calculation.
    # This comes from the rate text, NOT from the statistical reporting unit.
    duty_basis_unit <- if (is_qty_duty_relevant && !is.na(specific_rate_unit)) {
      specific_rate_unit
    } else {
      NA_character_
    }

    # Track where the duty basis unit was derived from
    quantity_source <- if (is_qty_duty_relevant && !is.na(specific_rate_unit)) {
      'rate_text'
    } else {
      NA_character_
    }

    # Determine 19 CFR 159.3 rounding rule
    rounding_rule <- determine_rounding_rule(general_parsed)

    # Calc status: flag items that need manual review
    # A specific or compound duty is NOT fully representable as an ad valorem
    # rate. Previously only rate_basis == 'unknown' was flagged, so 1,109 rows
    # in 2026_rev_9 (909 specific + 200 compound) carried base_rate 0 while
    # reporting calc_status 'ok' — a real duty, silently absent, and marked fine.
    #
    # base_ad_valorem_only marks rows where the ad valorem part is carried but a
    # per-unit component is not; base_not_representable marks rows where no
    # article-level rate exists at all (apportioned to components, defined by
    # cross-reference, or a Chapter 98 conditional provision).
    # ORDER MATTERS. `rate_basis == 'unknown'` used to be tested FIRST, which
    # short-circuited every row to 'needs_manual_review' before the precise
    # branches below could run — even though parse_duty_rate_string() had
    # already named exactly what the string was.
    #
    # Two parsers see the same text: parse_rate_extended() sets rate_basis and
    # returns 'unknown' for shapes it does not model, while
    # parse_duty_rate_string() returns a named status for those same shapes.
    # Testing the weaker one first discarded the stronger one's answer.
    #
    # Measured on 2025_rev_32: 722 rows carried rate_basis 'unknown', and 279 of
    # them had a rate string the named parser fully classifies —
    #   85 apportioned      "3.9% on the movement and case + 5.3% on the battery"
    #   66 compound         "15c each + 6.4%"   <- ad valorem half IS recoverable
    #   43 content-based    "2.5% on the value of the lead content"
    #   24 cross_reference  "the rate applicable to the natural juice in 2009"
    #   16 free_conditional "Free, under bond, as prescribed in U.S. note 1"
    # The remaining 443 have an EMPTY rate string. That was previously described
    # here as "404 already carry a correctly inherited rate — a labelling
    # artefact, not a missing duty". That was WRONG, and measuring it is what
    # showed why: of the 437 inheriting rows typed 'unknown', the rate stack and
    # the text stack named different ancestors in ALL 437.
    #   275  apparel ensembles (ch 61/62) whose nearest parent reads "The rate
    #        applicable to each garment in the ensemble if separately entered" —
    #        skipped, so the row took an unrelated ancestor's rate
    #   152  split-basis duties the type parser cannot model
    #        "1.7c/kg on lead content", "6c/kg on drained weight + 8.5%",
    #        "3.1% on the value of the rifle + 13% on the value of the telescope"
    # The first group was a wrong number, not a wrong label. Both are now taken
    # from a single ancestor, and an unrepresentable parent stops the walk.
    #
    # So consult the named status first and fall back to the generic bucket only
    # when nothing named it.
    calc_status <- if (identical(base_rate_status, 'specific_only') ||
                       identical(base_rate_status, 'compound')) {
      'base_ad_valorem_only'
    } else if (!is.na(base_rate_status) &&
               base_rate_status %in% c('apportioned', 'cross_reference',
                                       'ch98_conditional', 'alt_base_pct',
                                       'free_conditional')) {
      'base_not_representable'
    } else if (rate_basis == 'unknown') {
      'needs_manual_review'
    } else if (is_qty_duty_relevant && is.na(specific_rate_unit)) {
      'missing_duty_basis_unit'
    } else {
      'ok'
    }

    # Extract Chapter 99 references
    ch99_refs <- extract_chapter99_refs(item$footnotes)
    # Count BEFORE the tibble. Inside tibble() the `ch99_refs = list(ch99_refs)`
    # column shadows this local vector in the data mask, so a later
    # `length(ch99_refs)` measured the one-element LIST and returned 1 for every
    # product regardless of how many references it actually had.
    n_ch99_refs_actual <- length(ch99_refs)

    tibble(
      hts10 = hts10,
      description = description,
      base_rate = base_rate,
      base_rate_raw = general,
      base_rate_source = base_rate_source,
      rate_special = rate_special,
      rate_special_raw = special_raw,
      special_programs = list(special_parsed),
      rate_column2 = rate_column2,
      rate_column2_raw = other_raw,
      rate_basis = rate_basis,
      specific_amount = specific_amount,
      specific_rate_unit = specific_rate_unit %||% NA_character_,
      reported_unit_1 = reported_unit_1,
      reported_unit_2 = reported_unit_2,
      duty_basis_unit = duty_basis_unit,
      is_qty_duty_relevant = is_qty_duty_relevant,
      quantity_source = quantity_source,
      rounding_rule = rounding_rule,
      calc_status = calc_status,
      ch99_refs = list(ch99_refs),
      has_complex_rate = has_complex,
      n_ch99_refs = n_ch99_refs_actual,
      is_8digit_line = is_8digit_line
    )
  })

  # Post-pass: keep 8-digit lines only when they are LEAVES (no 10-digit
  # statistical children in this revision). An 8-digit parent with children
  # is a grouping row, not a product; an 8-digit leaf IS the tariff line.
  n_8digit_leaves <- 0L
  if (nrow(products) > 0) {
    ten_digit_prefixes <- unique(substr(products$hts10[!products$is_8digit_line], 1, 8))
    drop_8digit_parent <- products$is_8digit_line &
      substr(products$hts10, 1, 8) %in% ten_digit_prefixes
    n_8digit_leaves <- sum(products$is_8digit_line & !drop_8digit_parent)
    products <- products %>%
      filter(!drop_8digit_parent) %>%
      select(-is_8digit_line)
  }

  message('  Parsed products: ', nrow(products))
  message('  8-digit leaf lines retained (padded to 10): ', n_8digit_leaves)
  message('  With Chapter 99 refs: ', sum(products$n_ch99_refs > 0))
  message('  With complex rates: ', sum(products$has_complex_rate))
  message('  Inherited parent rate: ', n_inherited, ' (',
          round(n_inherited / nrow(products) * 100, 1), '%)')
  message('  With NA base_rate: ', sum(is.na(products$base_rate)))
  message('  Rate basis: ', paste(names(table(products$rate_basis)), '=',
          table(products$rate_basis), collapse = ', '))
  message('  Qty duty-relevant: ', sum(products$is_qty_duty_relevant))
  message('  With special rates: ', sum(!is.na(products$rate_special)))
  message('  With Column 2 rates: ', sum(!is.na(products$rate_column2)))
  message('  Calc status: ', paste(names(table(products$calc_status)), '=',
          table(products$calc_status), collapse = ', '))

  return(products)
}


#' Parse products from multiple HTS revisions
#'
#' @param revisions Vector of revision identifiers (e.g., c('basic', 'rev_1', 'rev_32'))
#' @param archive_dir Directory containing HTS JSON files
#' @return Named list of product tibbles
parse_all_revisions <- function(revisions, archive_dir = 'data/hts_archives') {
  results <- list()

  for (rev in revisions) {
    parsed <- parse_revision_id(rev)
    filename <- paste0('hts_', parsed$year, '_', parsed$rev, '.json')
    filepath <- file.path(archive_dir, filename)

    if (!file.exists(filepath)) {
      warning('File not found: ', filepath)
      next
    }

    message('\n=== Processing ', rev, ' ===')
    products <- parse_products(filepath)
    results[[rev]] <- products
  }

  return(results)
}


#' Compare products between two revisions
#'
#' @param old_products Products from older revision
#' @param new_products Products from newer revision
#' @return List with changes
compare_products <- function(old_products, new_products) {
  old_hts <- old_products$hts10

  new_hts <- new_products$hts10

  added_hts <- setdiff(new_hts, old_hts)
  removed_hts <- setdiff(old_hts, new_hts)

  # Check for Chapter 99 ref changes
  common <- intersect(old_hts, new_hts)

  old_refs <- old_products %>%
    filter(hts10 %in% common) %>%
    select(hts10, old_refs = ch99_refs, old_n = n_ch99_refs)

  new_refs <- new_products %>%
    filter(hts10 %in% common) %>%
    select(hts10, new_refs = ch99_refs, new_n = n_ch99_refs)

  ref_changes <- old_refs %>%
    inner_join(new_refs, by = 'hts10') %>%
    filter(old_n != new_n | map2_lgl(old_refs, new_refs, ~!setequal(.x, .y)))

  list(
    added = new_products %>% filter(hts10 %in% added_hts),
    removed = old_products %>% filter(hts10 %in% removed_hts),
    ref_changes = ref_changes,
    n_added = length(added_hts),
    n_removed = length(removed_hts),
    n_ref_changes = nrow(ref_changes)
  )
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Parse baseline and latest revision
  products_basic <- parse_products('data/hts_archives/hts_2025_basic.json')
  products_rev32 <- parse_products('data/hts_archives/hts_2025_rev_32.json')

  # Compare
  cat('\n=== Changes from Basic to Rev 32 ===\n')
  changes <- compare_products(products_basic, products_rev32)
  cat('Added products:', changes$n_added, '\n')
  cat('Removed products:', changes$n_removed, '\n')
  cat('Chapter 99 ref changes:', changes$n_ref_changes, '\n')

  if (changes$n_ref_changes > 0) {
    cat('\nSample Chapter 99 reference changes:\n')
    print(head(changes$ref_changes %>% select(hts10, old_n, new_n), 20))
  }

  # Save
  if (!dir.exists('data/processed')) dir.create('data/processed', recursive = TRUE)
  saveRDS(products_basic, 'data/processed/products_basic.rds')
  saveRDS(products_rev32, 'data/processed/products_rev32.rds')
  message('\nSaved product data')

  # Summary stats
  cat('\n=== Summary ===\n')
  cat('Basic edition: ', nrow(products_basic), ' products, ',
      sum(products_basic$n_ch99_refs > 0), ' with Ch99 refs\n', sep = '')
  cat('Rev 32: ', nrow(products_rev32), ' products, ',
      sum(products_rev32$n_ch99_refs > 0), ' with Ch99 refs\n', sep = '')
}
