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
  files<-c('resources/census_codes.csv','src/helpers.R','src/05_parse_policy_params.R','config/policy_params.yaml','src/section301_labor.R','src/ieepa_reciprocal_revision.R')
  sources<-lapply(files,function(file)list(id=paste0('s301fl-jurisdiction-',gsub('[^A-Za-z0-9]','-',file)),
    path=normalizePath(file.path(root,file),mustWork=TRUE),sha256=digest::digest(file=file.path(root,file),algo='sha256'),
    url='https://www.census.gov/foreign-trade/schedules/c/countrycode.html',
    citation=paste('Original investigation country text resolved against versioned Census codes and EU roster; input',file)))
  input<-tempfile(fileext='.json');output<-tempfile(fileext='.json');on.exit(unlink(c(input,output)),add=TRUE)
  jsonlite::write_json(list(revision_id=revision_id,products=as.list(sort(unique(as.character(products)))),
    jurisdictions=jurisdictions,jurisdiction_sources=sources),input,auto_unbox=TRUE,null='null',digits=NA)
  status<-system2('python3',c(shQuote(file.path(root,'src/section301_labor.py')),'--input',shQuote(input),shQuote(output)))
  if(status!=0L)stop('Forced-labor executable interaction failed; no aggregate fallback')
  jsonlite::fromJSON(output,simplifyVector=FALSE)
}
