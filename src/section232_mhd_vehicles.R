# Original MHD vehicle/bus actions and approved actual content valuation.
compile_s232_mhd_vehicles_fragment <- function(revision,products,countries=NULL,root=here::here()) {
  source(file.path(root,'src/shipment_build.R'))
  base<-load_shipment_base_source(revision,root)
  roster<-as.character(read.csv(file.path(root,'resources/census_codes.csv'),colClasses='character')$Code)
  if(is.null(countries))countries<-roster
  countries<-sort(unique(as.character(countries)))
  if(!length(countries)||any(!countries%in%roster))stop('Unresolved MHD vehicle origin inventory')
  column2<-sort(unique(as.character(unlist(lapply(base$gn3$country_names,resolve_country_name)))))
  if(!length(column2)||anyNA(column2))stop('Unresolved primary MHD Column2 inventory')
  input<-tempfile(fileext='.json');output<-tempfile(fileext='.json')
  on.exit(unlink(c(input,output)),add=TRUE)
  jsonlite::write_json(list(revision=revision,products=as.list(sort(unique(as.character(products)))),
    jurisdictions=list(all=as.list(countries),non_ntr=as.list(intersect(countries,column2))),jurisdiction_source=base$gn3$source),
    input,auto_unbox=TRUE,null='null')
  status<-system2('python3',c(shQuote(file.path(root,'src/section232_mhd_vehicles.py')),'--input',shQuote(input),'--output',shQuote(output)))
  if(status!=0L)stop('MHD vehicle original-source reconciliation failed; refusing modeled fallback')
  f<-jsonlite::fromJSON(output,simplifyVector=FALSE)
  deps<-c('src/section232_mhd_vehicles.R','src/section232_mhd_vehicles.py','src/shipment_vehicle_calendar.py',
    'src/section232_mhd_parts.py','src/section232_autos.py','src/section232_stacking.py','src/section232_semiconductors.py',
    'src/shipment_build.R','src/shipment_base_sources.py','src/parse_general_note_3.R','src/helpers.R','resources/census_codes.csv')
  f$compiler_dependencies<-setNames(lapply(deps,function(p)digest::digest(file=file.path(root,p),algo='sha256')),deps)
  f
}
