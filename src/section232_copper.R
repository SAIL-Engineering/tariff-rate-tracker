# Original copper action and valuation are independent of modeled metal shares.
compile_s232_copper_fragment <- function(revision,products,root=here::here()) {
  if(!grepl('^202[56]_(basic|rev_[0-9]+)$',revision))stop('Identified copper source revision required')
  input<-tempfile(fileext='.json');output<-tempfile(fileext='.json')
  on.exit(unlink(c(input,output)),add=TRUE)
  jsonlite::write_json(list(revision=revision,products=as.list(sort(unique(as.character(products))))),input,auto_unbox=TRUE,null='null')
  status<-system2('python3',c(shQuote(file.path(root,'src/section232_copper.py')),'--input',shQuote(input),'--output',shQuote(output)))
  if(status!=0L)stop('Copper original-source reconciliation failed; refusing aggregate or static-list fallback')
  f<-jsonlite::fromJSON(output,simplifyVector=FALSE)
  f$compiler_dependencies$adapter<-digest::digest(file=file.path(root,'src/section232_copper.R'),algo='sha256')
  f
}
