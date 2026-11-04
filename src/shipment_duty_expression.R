# Parse complete published duty expressions into the shared shipment AST.
# No trade quantities, average unit values, or modeled rates are accepted here.
# Unknown text is retained for source reconciliation; a recognized substring is
# never substituted for the unparsed remainder of a compound duty.

# Decode only known presentation syntax. Inner text, unknown tags, attributes,
# footnote references and legal conditions must still reach the complete parser.
normalize_shipment_duty_text <- function(text) {
  clean <- text;steps <- character()
  entities <- c('&nbsp;'=' ', '&#160;'=' ', '&#xA0;'=' ', '&cent;'='¢',
    '&#162;'='¢', '&#xA2;'='¢', '&dollar;'='$', '&#36;'='$', '&#x24;'='$', '&amp;'='&')
  for(key in names(entities))clean <- gsub(key,entities[[key]],clean,fixed=TRUE)
  if(!identical(clean,text))steps <- c(steps,'known_character_entities')
  # USITC's native extract also uses the nonstandard <il></il> for italics.
  stripped <- gsub('</?(?:i|il|b|u|sup|sub|strong|em)\\s*>','',clean,perl=TRUE,ignore.case=TRUE)
  stripped <- gsub('<br\\s*/?>',' ',stripped,perl=TRUE,ignore.case=TRUE)
  if(!identical(stripped,clean))steps <- c(steps,'presentation_markup')
  clean <- trimws(gsub('[[:space:]\u00a0]+',' ',stripped,perl=TRUE))
  list(text=clean,steps=as.list(steps))
}

parse_shipment_duty_expression <- function(text, value_fact = 'customs_value') {
  normalized <- list(text=NULL,steps=list())
  failed <- function(reason) list(status = 'unresolved_source', raw = text,
    normalized_text=normalized$text,normalization_steps=normalized$steps,
    formula = NULL, fact_definitions = list(), reason = reason)
  if (!is.character(text) || length(text) != 1 || is.na(text) || !nzchar(trimws(text)))
    return(failed('missing_duty_expression'))
  normalized <- normalize_shipment_duty_text(text)
  clean <- normalized$text
  definitions <- list()
  constraints <- list()
  definitions[[value_fact]] <- list(type = 'number', minimum = 0, unit = 'USD', label = 'Customs value (USD)')
  value <- function(x) list(value = x)
  fact <- function(x) list(fact = x)
  op <- function(name, ...) list(op = name, args = list(...))
  number <- '[0-9]+(?:\\.[0-9]+)?'
  match <- function(pattern, string) regmatches(string, regexec(pattern, string, perl = TRUE))[[1]]
  parse <- function(expression) {
    expression <- trimws(expression)
    if (tolower(expression) == 'free') return(value(0))
    # Explicit maxima/minima apply to the entire expression to their left.
    bound <- match('^(.+?),? but not (less|more) than (.+)$', expression)
    if (length(bound)) {
      a <- parse(bound[2]); b <- parse(bound[4])
      if (is.null(a) || is.null(b)) return(NULL)
      return(op(if (bound[3] == 'less') 'max' else 'min', a, b))
    }
    terms <- strsplit(expression, '\\s*\\+\\s*', perl = TRUE)[[1]]
    if (length(terms) > 1) {
      parsed <- lapply(terms, parse)
      if (any(vapply(parsed, is.null, logical(1)))) return(NULL)
      return(list(op = 'add', args = parsed))
    }
    percent <- match(paste0('^(', number, ')%$'), expression)
    if (length(percent)) return(op('multiply', fact(value_fact), op('divide',value(as.numeric(percent[2])),value(100))))
    # Component valuation is explicit in watch/clock and other compound rates.
    # It does not mean that the percentage applies to the article's full value.
    based <- match(paste0('^(', number, ')% on (?:the )?(?:value of the )?',
      '(case|case and strap, band or bracelet|strap, band or bracelet|battery|movement|movement and case|apparatus|lead content|rifle|telescopic sight|entire set)(?:, if any)?$'), expression)
    if (length(based)) {
      key <- paste0('value_', gsub('[^A-Za-z0-9]+', '_', based[3]))
      definitions[[key]] <<- list(type = 'number', minimum = 0, unit = 'USD',
        label = paste0('Value of ', based[3], ' (USD)'))
      constraints[[length(constraints) + 1L]] <<- list(
        test = op('lte', fact(key), fact(value_fact)), inputs = c(key, value_fact),
        label = 'Component value cannot exceed customs value')
      return(op('multiply', fact(key), op('divide',value(as.numeric(based[2])),value(100))))
    }
    # Unit strings are retained from the legal rate, never inferred from the
    # statistical reporting unit. Each distinct legal unit is a separate input.
    specific <- match(paste0('^(\\$?)(', number, ')(¢?)(?:/| per | )',
      '(clean kg|kg|g|t|lb|liter|liters|l|pf\\. ?liters?|bbl|doz\\.?|dozen|gross|head|each|article|pair|pairs|pr\\.|jewel|m|m2|m3|cm2|cm3|1000|1,000 pins|thousand|1000 pieces)',
      '((?: on (?:drained weight|contents and container|entire contents of container|ethyl alcohol content|lead content|tungsten content|molybdenum content|copper content|magnesium content)| of total sugars)?)$'), expression)
    if (!length(specific) || (specific[2] == '' && specific[4] == '') ||
        (specific[2] == '$' && specific[4] == '¢')) return(NULL)
    # The schedule prints one legal unit two ways ("2.1c/pf.liter" and
    # "2.1c/pf. liter"), which the pattern above accepts as `pf\\. ?liters?`.
    # The key below collapses punctuation, so both spellings share a key while
    # carrying different unit strings, and the valuation-fact checks in
    # section232_autos.py and section301_labor_pricing.py read that as a
    # conflicting definition. Canonicalise the spacing after a period only:
    # "clean kg" and "1,000 pins" keep their meaningful spaces, and the unit
    # is still taken from the legal rate rather than inferred.
    unit <- paste0(gsub('\\.[[:space:]]+', '.', specific[5]), specific[6])
    key <- paste0('quantity_', gsub('[^A-Za-z0-9]+', '_', unit))
    definitions[[key]] <<- list(type = 'number', minimum = 0, unit = unit,
      label = paste0('Quantity in ', unit, ' (legal duty basis)'))
    amount <- value(as.numeric(specific[3]))
    if(specific[4]=='¢')amount <- op('divide',amount,value(100))
    op('multiply',fact(key),amount)
  }
  formula <- parse(clean)
  if (is.null(formula)) return(failed('unparsed_complete_duty_expression'))
  list(status = 'parsed', raw = text, normalized_text=clean,normalization_steps=normalized$steps,formula = formula,
       fact_definitions = definitions, input_constraints = constraints, reason = NULL)
}
