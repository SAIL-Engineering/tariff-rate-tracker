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
  paths <- file.path(dir,sprintf('state-%03d',seq_along(states)))
  for(i in seq_along(states)) spill_legal_state(states[[i]],paths[i])
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

# ---- Streaming the snapshot without the panel ----
# The build writes a multi-state revision's snapshot straight from the spilled
# columns (write_legal_states_rds), so the panel is never held. readRDS() of
# that file must be identical() to what saveRDS() of the assembled panel gave:
# the downstream combine and every audit read the snapshot with readRDS().
stream_states <- function(states,chunk_rows=131072L,file=tempfile(fileext='.rds')) {
  dir <- file.path(tempdir(),paste0('stm-',as.integer(runif(1,1,1e9))))
  dir.create(dir,recursive=TRUE,showWarnings=FALSE);on.exit(unlink(dir,recursive=TRUE),add=TRUE)
  paths <- file.path(dir,sprintf('state-%03d',seq_along(states)))
  for(i in seq_along(states)) spill_legal_state(states[[i]],paths[i])
  write_legal_states_rds(paths,vapply(states,nrow,integer(1)),states[[1]][0,,drop=FALSE],
                         file,chunk_rows=chunk_rows)
  file
}

# Every column kind the panel carries, with NA in each, a non-ASCII string,
# and a deferred-string ALTREP column (as.character of numbers), which slices
# to another ALTREP unless copied -- the case the type-code check guards.
rich <- function(n,from,until,offset=0L) {
  if(n==0L) return(rich(3L,from,until,offset)[0,,drop=FALSE])
  s <- mkstate(n,from,until,offset)
  s$label <- c('Côte d’Ivoire',NA,'plain')[rep(1:3,length.out=n)]
  s$deferred <- as.character(offset+seq_len(n)+0.5)
  s$stamp <- as.POSIXct('2026-01-01 00:01:00',tz='America/New_York')+seq_len(n)
  s$rate_232[2] <- NA
  s
}
# Built fresh for every use: reading a deferred string's values (bind_rows,
# identical) expands it in place, after which it no longer slices to ALTREP.
# The spill must see it unexpanded, as the build's states can be.
fresh <- function() list(rich(5,'2026-10-23','2026-10-29',0L),rich(0,'2026-10-30','2026-11-02',100L),
                         rich(7,'2026-11-03','2026-11-09',200L),rich(5,'2026-11-10','2026-11-10',300L))
stopifnot(legal_states_streamable(fresh()[[1]]))
want <- dplyr::bind_rows(fresh())
for(chunk in c(131072L,3L,1L)) {   # whole states, ragged chunks, row by row
  f <- stream_states(fresh(),chunk_rows=chunk)
  got <- readRDS(f);unlink(f)
  stopifnot(identical(got,want))
}
f <- stream_states(lapply(fresh(),dplyr::as_tibble))
stopifnot(identical(readRDS(f),dplyr::bind_rows(lapply(fresh(),dplyr::as_tibble))));unlink(f)

# Where no symbol repeats (no classed columns), the decompressed file is
# byte-for-byte what serialize() of the in-memory assembly produces.
plain <- lapply(states,function(s) s[c('hts10','country','rate_232','count_i','code','flag')])
f <- stream_states(plain,chunk_rows=2L)
con <- gzfile(f,'rb');bytes <- readBin(con,'raw',n=1e7);close(con);unlink(f)
stopifnot(identical(bytes,serialize(spill_and_assemble(plain),NULL)))

# A failure part-way leaves no partial file and does not touch the existing
# snapshot; a list column is not streamable and is left to saveRDS().
target <- tempfile(fileext='.rds');saveRDS('previous',target)
err <- tryCatch({stream_states(bad,file=target);NULL},error=function(e) conditionMessage(e))
stopifnot(!is.null(err),grepl('rate_232',err,fixed=TRUE),identical(readRDS(target),'previous'),
          length(Sys.glob(paste0(target,'.partial-*')))==0L)
unlink(target)
lst <- states[[1]][0,,drop=FALSE];lst$parts <- list()
stopifnot(!legal_states_streamable(lst))

# The column spill is compressed: the uncompressed state RDS was 8.9 GB per
# 2025_rev_4 state, which a nearly full drive could not hold four of.
big <- data.frame(json=rep('{"rule":"9903.01.25","basis":"customs_value"}',2e5),
                  rate=rep(0.25,2e5),stringsAsFactors=FALSE)
d <- tempfile();spill_legal_state(big,d)
raw_size <- length(serialize(big,NULL))
stopifnot(.spill_bytes(d) < raw_size/20);unlink(d,recursive=TRUE)
cat('Streamed snapshot is identical to saveRDS of the assembled panel (types, ALTREP,',
    'chunk boundaries, empty states); failures leave the old snapshot; spill is compressed\n')
