# Bounded compiler-equivalence check, not a rate or revision build.
# Arguments: retained previous composer, actual emitted fragment, new report.
suppressPackageStartupMessages(library(tidyverse));source('src/helpers.R')
args<-commandArgs(TRUE);stopifnot(length(args)==3L,!file.exists(args[3]))
old<-new.env(parent=globalenv());current<-new.env(parent=globalenv())
sys.source(args[1],envir=old);sys.source('src/compile_shipment_rules.R',envir=current)
f<-current$read_shipment_rule_fragment(args[2])
b<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
b$revision<-sub('^ieepa_reciprocal_initial_','',f$id);b$dataset_version<-'composer-index-equivalence-not-production'
b$products<-as.list(sort(unique(unlist(lapply(f$rules,function(r)r$scope$hts_exact)))))
b$countries<-as.list(sort(unique(unlist(lapply(f$rules,function(r)r$scope$countries)))))
b$sources<-list(list(id='controlled-index-action',status='verified',sha256=paste(rep('0',64),collapse=''),url='https://example.invalid/index',citation='Controlled action for compiler equivalence only'))
b$rules<-list(list(id='controlled-metal',action_id='controlled-metal',authority='section_232',kind='duty',verification='verified',source_ids=list('controlled-index-action'),
 scope=list(hts_exact=b$products,countries=b$countries[1]),reporting_codes=list('9903.81.87'),when=list(value=TRUE),formula=list(value=50)))
b$claim_definitions<-list();b$fact_definitions<-list();b$coverage<-list();b$compiler<-NULL
b$valid_from<-f$supported_from;b$valid_until<-f$supported_until
before_time<-system.time(before<-old$compose_shipment_rules(b,list(f)))[['elapsed']]
after_time<-system.time(after<-current$compose_shipment_rules(b,list(f)))[['elapsed']]
stopifnot(identical(.shipment_canonical(before),.shipment_canonical(after)))
result<-list(contract_version='sail.composer-equivalence-check/v1',identical=TRUE,
 before_elapsed_seconds=before_time,after_elapsed_seconds=after_time,
 input_rules=length(f$rules)+length(b$rules),products=length(b$products),countries=length(b$countries),
 previous_composer_sha256=digest::digest(file=args[1],algo='sha256'),
 current_composer_sha256=digest::digest(file='src/compile_shipment_rules.R',algo='sha256'),
 fragment_sha256=digest::digest(file=args[2],algo='sha256'),
 canonical_output_sha256=digest::digest(.shipment_canonical(after),algo='sha256'),
 rates_calculated=FALSE,production_qualified=FALSE,
 limitation='One actual emitted reciprocal fragment plus a controlled action; not a full-series performance guarantee or legal coverage oracle.')
jsonlite::write_json(result,args[3],auto_unbox=TRUE,pretty=TRUE,digits=NA)
cat('Authority-indexed composition is byte-semantically identical for',result$input_rules,'input rules\n')
