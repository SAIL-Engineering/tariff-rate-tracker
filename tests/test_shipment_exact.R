source('src/resolve_shipment_duties.R')
# Independent round-trip/IEEE boundary checks, not epsilon comparisons.
values <- c(0,-0,.1,.2,.3,.25,.075,.137,.199,.0007,200.6,1003,
  .Machine$double.xmin,.Machine$double.xmax,5e-324,1e-323,1e-300,-1e-300,
  1.2345678901234567,0.30000000000000004,9007199254740991)
for(x in values)stopifnot(identical(.shipment_rational_number(.shipment_rational(x)),x))
two <- gmp::as.bigz(2)
stopifnot(.shipment_rational_number(gmp::as.bigq(two^53+1,two^53))==1,
  .shipment_rational_number(gmp::as.bigq(two^53+3,two^53))==1.0000000000000004,
  .shipment_rational_number(gmp::as.bigq(1,two^1075))==0,
  .shipment_rational_number(gmp::as.bigq(3,two^1075))==1e-323,
  .shipment_rational(.1)+.shipment_rational(.2)==.shipment_rational(.3))
# Converting one component for display must not destroy a dependency's exact
# rational; reversing actions must preserve the exactly accumulated subtotal.
cases <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)
matched <- Filter(function(c)identical(c$name,'cached fractional rule amount retains exact comparison'),cases)
stopifnot(length(matched)==1L)
c <- matched[[1]]
a <- evaluate_shipment_bundle(c$bundle,c$hts10,c$country,c$entry_at,c$facts)
c$bundle$rules <- rev(c$bundle$rules)
b <- evaluate_shipment_bundle(c$bundle,c$hts10,c$country,c$entry_at,c$facts)
stopifnot(a$status=='complete',identical(a$complete_total,10+1/3),identical(a,b))
cat('Exact decimal comparisons, cached fractions, IEEE ties/subnormals and order invariance passed\n')
