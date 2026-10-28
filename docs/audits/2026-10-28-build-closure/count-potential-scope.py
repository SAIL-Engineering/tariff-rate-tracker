"""Count source-defined candidates, not incorrect rates or actual shipments."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'src'))
from shipment_base_sources import extract_rows
import section301_labor as labor

parser = argparse.ArgumentParser()
parser.add_argument('--source-census', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
census = json.load(gzip.open(args.source_census, 'rt'))
history = labor.load_history()
floor_origins = sorted({c for a in history['floor_policy']['actions']
                        for c in census['origin_resolution'][a['country_text']]})
review = json.loads((labor.EVIDENCE / 'annex-reconciliation.json').read_bytes())
by_charge = {h['reporting_code']: a['country_text'] for a in history['actions'] for h in a['headings']}
rows = []; floor_products = set(); missing_products = set(); missing_countries = set()
for r in census['revisions']:
    if not r['heading_inventory']:
        continue
    raw = (ROOT / f'data/hts_archives/hts_{r["revision"]}.json').read_bytes()
    if hashlib.sha256(raw).hexdigest() != r['native_hts_sha256']:
        raise ValueError('Native source differs from reconciled census')
    products = [q['hts10'] for q in extract_rows(json.loads(raw))['products']]
    floor_products.update(products); omissions = []
    for d in review['decisions']:
        annex = next(a for a in history['product_exemptions'] if a['reporting_code'] == d['reporting_code'])
        countries = sorted({c for code in annex['target_reporting_codes']
                            for c in census['origin_resolution'][by_charge[code]]})
        hit = sorted(p for p in products if any(p.startswith(s) for s in d['missing_from_native']))
        missing_products.update(hit); missing_countries.update(countries)
        omissions.append(dict(reporting_code=d['reporting_code'], products=hit, countries=countries,
                              product_origin_cells=len(hit)*len(countries), condition=annex['condition'],
                              condition_text=annex['condition_text']))
    rows.append(dict(revision=r['revision'], ordinary_product_count=len(products),
                     floor_origin_count=len(floor_origins), floor_product_origin_cells=len(products)*len(floor_origins),
                     annex_omissions=omissions))
result = dict(contract_version='sail.shipment-potential-scope/v1',
              source_census_sha256=hashlib.sha256(args.source_census.read_bytes()).hexdigest(), revision_count=len(rows),
              floor=dict(distinct_hts10=len(floor_products), origins=floor_origins,
                         product_origin_revision_cells=sum(r['floor_product_origin_cells'] for r in rows)),
              published_native_annex_omission=dict(distinct_hts10=len(missing_products), origins=sorted(missing_countries),
                  product_origin_revision_cells=sum(a['product_origin_cells'] for r in rows for a in r['annex_omissions'])),
              revisions=rows,
              qualification='Potential revision-valid populations only. Conditional claims, product/use facts, other exemptions and authority interactions change actual liability. These are not counts of incorrect database rates or actual shipments, and sub-day legal intervals are not multiplied into these cells.')
args.output.write_bytes(gzip.compress((json.dumps(result, indent=2)+'\n').encode(), mtime=0))
