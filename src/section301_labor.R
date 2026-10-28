# Original note52 inventory, independent of aggregate forced-labor parameters.
load_s301_labor_history <- function(root=here::here()) {
  output<-tempfile(fileext='.json');on.exit(unlink(output),add=TRUE)
  status<-system2('python3',c(shQuote(file.path(root,'src/section301_labor.py')),'--history',shQuote(output)))
  if(status!=0L)stop('Original forced-labor source reconciliation failed; no config-rate fallback')
  jsonlite::fromJSON(output,simplifyVector=FALSE)
}

compile_s301_labor_fragment <- function(revision_id,products,root=here::here()) {
  history<-load_s301_labor_history(root)
  if(!exists('resolve_original_action_origins',mode='function'))source(file.path(root,'src/ieepa_reciprocal_revision.R'))
  jurisdictions<-setNames(lapply(history$actions,function(a)resolve_original_action_origins(a$country_text)),
    vapply(history$actions,`[[`,character(1),'country_text'))
  files<-c('resources/census_codes.csv','resources/country_qualified_names.csv','resources/country_name_aliases.csv','src/helpers.R','src/05_parse_policy_params.R','config/policy_params.yaml','src/section301_labor.R','src/ieepa_reciprocal_revision.R')
  sources<-lapply(files,function(file)list(id=paste0('s301fl-jurisdiction-',gsub('[^A-Za-z0-9]','-',file)),
    path=normalizePath(file.path(root,file),mustWork=TRUE),sha256=digest::digest(file=file.path(root,file),algo='sha256'),
    url='https://www.census.gov/foreign-trade/schedules/c/countrycode.html',
    citation=paste('Original investigation country text resolved against versioned Census codes and EU roster; input',file)))
  source(file.path(root,'src/shipment_build.R'))
  base<-load_shipment_base_source(revision_id,root)
  window<-shipment_source_selection_window(revision_id,root)
  operative<-.shipment_time(window$until)>.shipment_time(history$from_)
  amounts<-if(operative)compile_shipment_column1_references(base,products) else list()
  benchmark_sources<-if(operative)list(c(list(id=paste0('USITC-',revision_id,'-note52-column1')),base$source),
    c(list(id=paste0('USITC-',revision_id,'-shipment-gn3')),base$gn3$source)) else list()
  input<-tempfile(fileext='.json');output<-tempfile(fileext='.json');on.exit(unlink(c(input,output)),add=TRUE)
  jsonlite::write_json(list(revision_id=revision_id,products=as.list(sort(unique(as.character(products)))),
    jurisdictions=jurisdictions,jurisdiction_sources=sources,column1_references=amounts,benchmark_sources=benchmark_sources,
    benchmark_program_symbols=base$gn3$program_symbols),input,auto_unbox=TRUE,null='null',digits=NA)
  status<-system2('python3',c(shQuote(file.path(root,'src/section301_labor.py')),'--input',shQuote(input),shQuote(output)))
  if(status!=0L)stop('Forced-labor executable interaction failed; no aggregate fallback')
  jsonlite::fromJSON(output,simplifyVector=FALSE)
}
