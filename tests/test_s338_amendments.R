# Primary-source annex regressions, independent of wide output snapshots.
source('src/helpers.R')
cfg <- load_policy_params()$SECTION_338
before <- load_s338_actions(cfg, as.Date('2026-09-14'))
after <- load_s338_actions(cfg, as.Date('2026-09-15'))
amendments <- jsonlite::fromJSON(cfg$amendments_file, simplifyVector = FALSE)

# Each amendment is checked across ITS OWN effective date, not a window fixed at
# 2026-09-15. A second motor_vehicles amendment (2026-10-30, Proclamation 11076)
# was added after this test was written, and because the loop compared every
# amendment against the 09-14/09-15 pair, the new one was asserted over a window
# that predates it -- it could only fail, and it was the sole thing proving the
# amendment applies at all. Deriving the window per amendment keeps every future
# dated amendment self-verifying instead of needing this test edited each time.
# The prior-day set is the cumulative state, so sequential amendments to one
# program compose rather than each being measured against the original annex.
for (a in amendments) {
  stopifnot(!is.null(a[['effective_at']]))  # exact key: a$effective partial-matches it
  eff <- as.Date(substr(a[['effective_at']], 1, 10))
  prior <- load_s338_actions(cfg, eff - 1)
  on_eff <- load_s338_actions(cfg, eff)
  old <- prior$hts_code[prior$program == a$program]
  new <- on_eff$hts_code[on_eff$program == a$program]
  stopifnot(setequal(new, union(setdiff(old, unlist(a$delete)), unlist(a$insert))))
  stopifnot(all(!on_eff$s232_exempt[on_eff$program == a$program]))
  # The delete set must name codes that were actually there, or a typo in the
  # annex transcription silently deletes nothing and the scope stays too wide.
  stopifnot(all(unlist(a$delete) %in% old))
  stopifnot(length(setdiff(unlist(a$insert), new)) == 0L)
}
stopifnot(length(amendments) >= 3L)  # alcohol 09-15, motor_vehicles 09-15 + 10-30
stopifnot(all(after$s232_exempt[after$program == 'dairy']))
rows <- tibble(hts10 = c('2208306075', '2208306085', '2208700030', '2208700060',
                        '8537109120', '8537109130', '9507100040', '9507100080'),
               country = '1220', statutory_rate_232 = 0, rate_232 = 0,
               s232_annex = NA_character_)
stopifnot(all(compute_s338_rates(rows, cfg, as.Date('2026-08-21'), TRUE) == 0))
stopifnot(all(compute_s338_rates(rows, cfg, as.Date('2026-08-22'), TRUE) == 0.50))
stopifnot(identical(compute_s338_rates(rows, cfg, as.Date('2026-09-15'), TRUE),
                    c(0.5, 0, 0.5, 0, 0, 0.5, 0.5, 0)))
rows$statutory_rate_232 <- 0.25
stopifnot(all(compute_s338_rates(rows, cfg, as.Date('2026-09-14'), TRUE) == 0))
stopifnot(identical(compute_s338_rates(rows, cfg, as.Date('2026-09-15'), TRUE),
                    c(0.5, 0, 0.5, 0, 0, 0.5, 0.5, 0)))
rows$country <- '2010'
stopifnot(all(compute_s338_rates(rows, cfg, as.Date('2026-09-15'), TRUE) == 0))
message('Section 338: suspension, all amendment rows, exact HTS10 removals and stacking passed')
# Retained annex evidence is an input, not an unchecked citation label.
bad <- amendments;bad[[1]]$sha256<-paste(rep('0',64),collapse='')
tmp<-tempfile(fileext='.json');jsonlite::write_json(bad,tmp,auto_unbox=TRUE)
badcfg<-cfg;badcfg$amendments_file<-tmp
stopifnot(inherits(try(load_s338_actions(badcfg,as.Date('2026-09-15')),silent=TRUE),'try-error'))
# Source order has no effect on independent dated actions.
jsonlite::write_json(rev(amendments),tmp,auto_unbox=TRUE)
reordered<-load_s338_actions(badcfg,as.Date('2026-09-15'))
stopifnot(identical(after,reordered))
unlink(tmp)
message('Section 338 rejects altered evidence and preserves amendment-order invariance')
