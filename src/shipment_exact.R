# Exact internal arithmetic for the decimal values supplied in JSON/facts.
# No tolerance, cent rounding or assumed customs rounding policy is applied.
# Public amounts remain JSON numbers; never reconstruct an intermediate rational
# from a rounded double (especially for comparisons and rule dependencies).
.shipment_decimal_text <- function(x) {
  stopifnot(is.numeric(x),length(x)==1L,is.finite(x))
  for(digits in seq_len(17L)) {
    text <- chartr(',','.',sprintf('%.*g',digits,x))
    if(identical(as.numeric(text),as.numeric(x)))return(text)
  }
  stop('No round-trip decimal representation')
}

.shipment_rational <- function(x) {
  text <- .shipment_decimal_text(x)
  fields <- strsplit(tolower(text),'e',fixed=TRUE)[[1]]
  exponent <- if(length(fields)==2L)as.integer(fields[2]) else 0L
  fractional <- if(grepl('.',fields[1],fixed=TRUE))nchar(sub('.*\\.','',fields[1])) else 0L
  digits <- gsub('.','',fields[1],fixed=TRUE)
  # GMP auto-detects a leading zero as octal; decimal JSON is always base ten.
  digits <- sub('^(-?)0+(?=[0-9])','\\1',digits,perl=TRUE)
  numerator <- gmp::as.bigz(digits)
  power <- exponent-fractional
  if(power>=0L)gmp::as.bigq(numerator* gmp::as.bigz(10)^power) else
    gmp::as.bigq(numerator,gmp::as.bigz(10)^(-power))
}

.shipment_rational_number <- function(q) {
  # GMP's direct mpq-to-double conversion truncates. Round once to IEEE nearest,
  # ties to even, matching the TypeScript boundary conversion, including denormals.
  n <- gmp::numerator(q);d <- gmp::denominator(q)
  if(n==0)return(0)
  sign <- if(n<0)-1 else 1;n <- abs(n)
  e <- as.integer(gmp::sizeinbase(n,2)-gmp::sizeinbase(d,2))
  two <- gmp::as.bigz(2)
  if((e>=0L&&n<d*two^e)||(e<0L&&n*two^(-e)<d))e <- e-1L
  shift <- if(e < -1022L)1074L else 52L-e
  if(shift>=0L)n <- n*two^shift else d <- d*two^(-shift)
  integer <- n %/% d;remainder <- n %% d
  if(2*remainder>d||(2*remainder==d&&integer %% 2==1))integer <- integer+1
  sign*as.numeric(integer)*2^(-shift)
}
