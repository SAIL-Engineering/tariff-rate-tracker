# Primary-source annex regressions, independent of wide output snapshots.
source('src/helpers.R')
cfg <- load_policy_params()$SECTION_338
before <- load_s338_actions(cfg, as.Date('2026-09-14'))
after <- load_s338_actions(cfg, as.Date('2026-09-15'))
amendments <- jsonlite::fromJSON(cfg$amendments_file, simplifyVector = FALSE)
for (a in amendments) {
  old <- before$hts_code[before$program == a$program]
  new <- after$hts_code[after$program == a$program]
  stopifnot(setequal(new, union(setdiff(old, unlist(a$delete)), unlist(a$insert))))
  stopifnot(all(!after$s232_exempt[after$program == a$program]))
}
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
