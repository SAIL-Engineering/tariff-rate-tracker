suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/legal_intervals.R')
source('src/resolve_shipment_duties.R')
# Source-only all-revision tiling test. No rate/revision build is invoked.
path<-tempfile(fileext='.json')
script<-paste(
 "import sys,json;sys.path.insert(0,'src')",
 'from ieepa_reciprocal_initial import initial_history',
 'from ieepa_reciprocal_history import history',
 'from ieepa_reciprocal_later import legal_instants',
 "p,s=initial_history(),history();json.dump(dict(policy=p,scope=s,instants=sorted(legal_instants(p,s))),open(sys.argv[1],'w'))",sep='\n')
status<-system2('python3',c('-c',shQuote(script),shQuote(path)))
stopifnot(status==0L)
x<-jsonlite::fromJSON(path,simplifyVector=FALSE);unlink(path)
calendar<-load_revision_dates() %>% filter(grepl('^202[56]_',revision)) %>% arrange(effective_date)
# Take the horizon from the same policy params the build reads. Hardcoding it
# pinned this test to the horizon of the day it was written, so registering
# 2026_rev_22 (effective 2026-10-30) past the old 2026-10-22 bound made
# revision_legal_segments() reject its own calendar with 'Invalid revision
# horizon'. Derived, it tracks the next extension too.
horizon<-load_policy_params()$SERIES_HORIZON_END
stopifnot(!is.na(horizon),horizon>=max(calendar$effective_date))
instants<-vapply(x$instants,.shipment_time,numeric(1));stopifnot(!anyNA(instants))
reports<-list();checked<-0L
for(i in seq_len(nrow(calendar))) {
 row<-calendar[i,];segments<-revision_legal_segments(row$revision,calendar,
   list(SERIES_HORIZON_END=horizon),list(x$policy,x$scope))
 # Compare using POSIXct to avoid interpreting a date-only input as an entry.
 lo<-as.numeric(as.POSIXct(paste(row$effective_date,'00:00:00'),tz='America/New_York'))
 end<-if(i<nrow(calendar))calendar$effective_date[i+1L] else horizon+1
 hi<-as.numeric(as.POSIXct(paste(end,'00:00:00'),tz='America/New_York'))
 selected<-which(instants>=lo & instants<hi)
 days<-unique(substr(unlist(x$instants[selected]),1,10))
 stopifnot(all(days %in% as.character(segments$valid_from)))
 checked<-checked+length(selected)
 reports[[length(reports)+1L]]<-list(revision=row$revision,segments=segments,typed_instants=unname(x$instants[selected]))
}
result<-list(contract_version='sail.reciprocal-calendar-check/v1',revisions=nrow(calendar),checked_instants=checked,
 reports=reports,rates_calculated=FALSE,legal_coverage_complete=FALSE)
out<-Sys.getenv('RECIPROCAL_CALENDAR_REPORT','')
if(nzchar(out)){stopifnot(!file.exists(out));jsonlite::write_json(result,out,auto_unbox=TRUE,null='null',digits=NA,pretty=TRUE)}
cat(nrow(calendar),'revision calendars retain',checked,'typed original-law instants; no rates calculated\n')
