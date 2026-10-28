# Original-annex automobile/parts rules. Never consume a modeled sector rate,
# Canada/Mexico utilization share, assembly credit or inferred reporting suffix.
compile_s232_autos_fragment <- function(revision_id,products,countries=NULL,root=here::here(),native_interactions=TRUE) {
  if(!grepl('^202[56]_(basic|rev_[0-9]+)$',revision_id))stop('Identified automobile source revision required')
  pdf <- file.path(root,'data/us_notes',paste0('chapter99_',revision_id,'.pdf'))
  hts <- file.path(root,'data/hts_archives',paste0('hts_',revision_id,'.json'))
  if(!file.exists(pdf)||!file.exists(hts))stop('Missing revision-bound automobile source')
  roster <- as.character(read.csv(file.path(root,'resources/census_codes.csv'),colClasses='character')$Code)
  if(is.null(countries))countries <- roster
  countries <- sort(unique(as.character(countries)))
  if(!length(countries)||any(!countries %in% roster))stop('Unresolved automobile origin inventory')
  country <- function(name) {
    value <- as.character(resolve_country_name(name))
    if(!length(value)||anyNA(value)||any(!value %in% roster))stop('Unresolved automobile agreement origin: ',name)
    intersect(countries,value)
  }
  jurisdictions <- c(list(all=as.list(countries)),setNames(lapply(c('United Kingdom','Japan','European Union','South Korea','Taiwan'),
    function(n)as.list(country(n))),c('United Kingdom','Japan','European Union','South Korea','Taiwan')))
  # Use the same primary GN3(b) roster as the base compiler. Column2's printed
  # "No change" must not be interpreted as a zero-content automobile exemption.
  source(file.path(root,'src/shipment_build.R'))
  base <- load_shipment_base_source(revision_id,root)
  native <- setNames(base$products,vapply(base$products,`[[`,character(1),'hts10'))
  if(any(!products %in% names(native)))stop('Automobile product is not valid in the identified revision')
  amounts <- compile_shipment_column1_references(base,products,question_prefix='auto_column1_general_expression')
  column2 <- sort(unique(as.character(unlist(lapply(base$gn3$country_names,resolve_country_name)))))
  if(!length(column2)||anyNA(column2))stop('Unresolved automobile Column2 inventory')
  jurisdictions$non_ntr <- as.list(intersect(countries,column2))
  input <- tempfile(fileext='.json');output <- tempfile(fileext='.json')
  on.exit(unlink(c(input,output)),add=TRUE)
  jsonlite::write_json(list(products=as.list(sort(unique(as.character(products)))),jurisdictions=jurisdictions,
    jurisdiction_source=base$gn3$source,base_amounts=amounts,base_program_symbols=base$gn3$program_symbols,
    native_window=if(native_interactions)shipment_source_selection_window(revision_id,root) else NULL),
    input,auto_unbox=TRUE,null='null',digits=NA)
  status <- system2('python3',c(shQuote(file.path(root,'src/section232_autos.py')),
    '--pdf',shQuote(pdf),'--hts',shQuote(hts),'--revision',shQuote(revision_id),
    '--input',shQuote(input),'--output',shQuote(output)))
  if(status!=0L)stop('Automobile source reconciliation failed; refusing aggregate fallback')
  result <- jsonlite::fromJSON(output,simplifyVector=FALSE)
  dependencies <- c('src/section232_autos.R','src/shipment_build.R','src/shipment_duty_expression.R','src/shipment_base_sources.py',
    'src/helpers.R','resources/census_codes.csv')
  result$compiler_dependencies <- setNames(lapply(dependencies,function(p)
    digest::digest(file=file.path(root,p),algo='sha256')),dependencies)
  result
}
