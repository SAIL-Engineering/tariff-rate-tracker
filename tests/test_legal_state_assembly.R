suppressPackageStartupMessages({library(tidyverse);library(here)})
source(here('src','legal_intervals.R'))

# Assembling a revision's legal states must not depend on holding them all in
# memory at once. `bind_rows(states)` allocated the combined frame while every
# state was still resident, so peak memory was 2 x N x 3.42 GB; 2026_rev_22 has
# four states and died at a 51.5 GB peak. The spilled assembler must produce a
# frame IDENTICAL to what bind_rows produced -- this is the duty panel, so a
# changed type or a reordered row is a changed legal answer.

mkstate <- function(n,from,until,offset=0L) {
  data.frame(
    hts10=sprintf('%010d',offset+seq_len(n)),
    country=rep(c('2010','5700'),length.out=n),
    rate_232=as.numeric(seq_len(n))/100,
    count_i=offset+seq_len(n),
    code=c(NA_character_,'9903.81.90')[rep(1:2,length.out=n)],
    flag=c(TRUE,FALSE,NA)[rep(1:3,length.out=n)],
    metal=factor(c('steel','aluminum')[rep(1:2,length.out=n)],levels=c('steel','aluminum','copper')),
    stamped=as.Date('2026-01-01')+seq_len(n),
    valid_from=as.Date(from),valid_until=as.Date(until),
    stringsAsFactors=FALSE)
}
states <- list(mkstate(5,'2026-10-23','2026-10-29',0L),
               mkstate(5,'2026-10-30','2026-11-02',100L),
               mkstate(5,'2026-11-03','2026-11-09',200L),
               mkstate(5,'2026-11-10','2026-11-10',300L))

spill_and_assemble <- function(states) {
  dir <- file.path(tempdir(),paste0('asm-',as.integer(runif(1,1,1e9))))
  dir.create(dir,recursive=TRUE,showWarnings=FALSE);on.exit(unlink(dir,recursive=TRUE),add=TRUE)
  paths <- file.path(dir,sprintf('state-%03d.rds',seq_along(states)))
  for(i in seq_along(states)) saveRDS(states[[i]],paths[i],compress=FALSE)
  assemble_legal_states(paths,vapply(states,nrow,integer(1)),states[[1]][0,,drop=FALSE])
}

expected <- dplyr::bind_rows(states)
actual <- spill_and_assemble(states)
stopifnot(identical(expected,actual))

# Column types must survive the round trip individually, not just in aggregate.
for(col in names(expected))
  stopifnot(identical(class(expected[[col]]),class(actual[[col]])),
            identical(expected[[col]],actual[[col]]))
stopifnot(identical(levels(actual$metal),c('steel','aluminum','copper')))

# Row order must be segment order, so valid_from is non-decreasing and the
# window boundaries land where validate_snapshot_intervals expects them.
stopifnot(!is.unsorted(actual$valid_from),
          identical(nrow(actual),20L),
          identical(as.character(min(actual$valid_from)),'2026-10-23'),
          identical(as.character(max(actual$valid_until)),'2026-11-10'))

# A single state needs no spill at all and must come back untouched.
one <- spill_and_assemble(states[1])
stopifnot(identical(one,states[[1]]))

# bind_rows silently coerces a type that disagrees between states. For a duty
# panel that is a defect, not a convenience: refuse it instead.
bad <- states;bad[[2]]$rate_232 <- as.character(bad[[2]]$rate_232)
err <- tryCatch({spill_and_assemble(bad);NULL},error=function(e) conditionMessage(e))
stopifnot(!is.null(err),grepl('rate_232',err,fixed=TRUE))

# A missing or extra column is likewise refused rather than filled with NA.
bad2 <- states;bad2[[3]]$extra <- 1
err2 <- tryCatch({spill_and_assemble(bad2);NULL},error=function(e) conditionMessage(e))
stopifnot(!is.null(err2),grepl('column',err2))

# Tibbles must round trip as tibbles, since the real states are tbl_df.
tb <- lapply(states,dplyr::as_tibble)
stopifnot(identical(dplyr::bind_rows(tb),spill_and_assemble(tb)))

cat('Spilled legal-state assembly is identical to bind_rows;',
    'types, order and class preserved; disagreeing schemas refused\n')

# The schema guard must also run BEFORE a state is spilled, so a four-state
# revision fails on the state that introduces the disagreement (~20 min) rather
# than after computing all four and starting to assemble (~46 min).
tmpl <- states[[1]][0,,drop=FALSE]
stopifnot(isTRUE(check_legal_state_schema(states[[2]],tmpl,2L)))
e3 <- tryCatch({check_legal_state_schema(
  within(states[[2]],rate_232 <- as.character(rate_232)),tmpl,2L);NULL},
  error=function(e) conditionMessage(e))
stopifnot(!is.null(e3),grepl('Legal state 2',e3,fixed=TRUE),
          grepl('rate_232',e3,fixed=TRUE),grepl('character',e3,fixed=TRUE))

# The RSS probe must keep working past 8 digits. The kernel pads the value to a
# fixed width, so above ~9.5 GB the separator is a bare tab and a parser that
# expected a space before the number returned NA -- silently, at exactly the
# sizes worth reporting.
m <- .legal_state_rss()
stopifnot(is.finite(m[['rss']]),is.finite(m[['peak']]),m[['rss']]>0,
          m[['peak']]>=m[['rss']])
cat('Schema guard runs before the spill; RSS probe survives 8-digit values\n')
