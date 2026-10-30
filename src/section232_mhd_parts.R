# Source-derived listed and certified MHD part actions; no economic allocations.
compile_s232_mhd_parts_fragment <- function(revision,products,root=here::here()) {
  input<-tempfile(fileext='.json');output<-tempfile(fileext='.json')
  on.exit(unlink(c(input,output)),add=TRUE)
  jsonlite::write_json(list(revision=revision,products=as.list(sort(unique(as.character(products))))),input,auto_unbox=TRUE,null='null')
  status<-system2('python3',c(shQuote(file.path(root,'src/section232_mhd_parts.py')),'--input',shQuote(input),'--output',shQuote(output)))
  if(status!=0L)stop('MHD parts original-source reconciliation failed; refusing modeled fallback')
  f<-jsonlite::fromJSON(output,simplifyVector=FALSE)
  deps<-c('src/section232_mhd_parts.R','src/section232_mhd_parts.py','src/section232_vehicle_certified.py',
    'src/section232_autos.py','src/section232_stacking.py','src/section232_semiconductors.py','src/shipment_base_sources.py')
  f$compiler_dependencies<-setNames(lapply(deps,function(p)digest::digest(file=file.path(root,p),algo='sha256')),deps)
  f
}
