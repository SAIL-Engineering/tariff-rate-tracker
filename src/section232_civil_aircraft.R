# Independent aircraft-agreement history. Original sources determine liability;
# an IEEPA collection window does not terminate a Section232 concession.
compile_s232_civil_aircraft_fragment <- function(revision_id,products,root=here::here()) {
  if(!grepl('^202[56]_(basic|rev_[0-9]+)$',revision_id))stop('Identified aircraft source revision required')
  paths<-replicate(3,tempfile(fileext='.json'));on.exit(unlink(paths),add=TRUE)
  script<-file.path(root,'src/section232_civil_aircraft.py')
  status<-system2('python3',c(shQuote(script),'--history',shQuote(paths[1])))
  if(status!=0L)stop('Civil-aircraft original-source history failed; no guessed concession')
  history<-jsonlite::fromJSON(paths[1],simplifyVector=FALSE)
  if(!exists('match_countries',mode='function'))source(file.path(root,'src/05_parse_policy_params.R'))
  if(!exists('resolve_original_action_origins',mode='function'))source(file.path(root,'src/ieepa_reciprocal_revision.R'))
  lookup<-build_country_lookup(file.path(root,'resources/census_codes.csv'))
  jurisdictions<-setNames(lapply(history$actions,function(a)resolve_original_action_origins(a$country_text)),
    vapply(history$actions,`[[`,character(1),'reporting_code'))
  files<-c('resources/census_codes.csv','resources/country_qualified_names.csv','resources/country_name_aliases.csv','src/helpers.R','src/05_parse_policy_params.R','config/policy_params.yaml','src/section232_civil_aircraft.R','src/ieepa_reciprocal_revision.R')
  sources<-lapply(files,function(file)list(id=paste0('aircraft-jurisdiction-',gsub('[^A-Za-z0-9]','-',file)),
    path=normalizePath(file.path(root,file),mustWork=TRUE),sha256=digest::digest(file=file.path(root,file),algo='sha256'),
    url='https://www.census.gov/foreign-trade/schedules/c/countrycode.html',
    citation=paste('Derived origin mapping: original country text, versioned Census codes and EU roster; input',file)))
  jsonlite::write_json(list(revision_id=revision_id,products=as.list(sort(unique(as.character(products)))),
    jurisdictions=jurisdictions,jurisdiction_sources=sources),paths[2],auto_unbox=TRUE,null='null',digits=NA)
  status<-system2('python3',c(shQuote(script),'--input',shQuote(paths[2]),shQuote(paths[3])))
  if(status!=0L)stop('Civil-aircraft executable history failed; no reciprocal or aggregate fallback')
  jsonlite::fromJSON(paths[3],simplifyVector=FALSE)
}
