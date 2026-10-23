suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/duty_ledger.R')
out<-tempfile();dir.create(out)
row<-tibble(hts10='1234567890',country='TEST',rate=.1)
for(day in c('2026-07-21','2026-07-22')) {
 duty_ledger_init(row,'test',day)
 if(day=='2026-07-22') row$rate<-NA_real_
 record_duty(row,'synthetic','synthetic','rate','fixture','synthetic')
 duty_ledger_save(out,revision='test',entry_day=day)
}
stopifnot(length(list.files(out))==4,
  all(is.na(duty_ledger_rows()$after)),
  all(duty_ledger_rows()$effective_date=='2026-07-22'),
  duty_ledger_steps()$n_unresolved==1,is.na(duty_ledger_steps()$sum_rate))
stopifnot(inherits(try(duty_ledger_load('test',out),silent=TRUE),'try-error'))
duty_ledger_load('test',out,entry_day='2026-07-21')
stopifnot(duty_ledger_rows()$after==.1)
duty_ledger_load('test',out,entry_day='2026-07-22')
stopifnot(is.na(duty_ledger_rows()$after))
unlink(out,recursive=TRUE)
cat('Legal states preserve independent ledgers and unresolved amounts cannot become zero\n')
