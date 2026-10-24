#!/usr/bin/env python3
"""Reconcile Chapter 98 clauses across every configured Section 301 revision.

Source and formula audit only: no rate/timeseries rebuild or database access.
"""
import argparse
import gzip
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from section301_sources import extract, verify_revision_header, sha
from section301_chapter98 import compile_valuations
from chapter98_rules import treatment


def original_policy():
    root=ROOT/'resources/legal_evidence/section301_chapter98'
    review=json.loads((root/'review.json').read_bytes())
    for source in review['sources']:
        for name,hash_key in [('artifact','sha256'),('text_artifact','text_sha256'),('ocr_artifact','ocr_sha256')]:
            if name in source and sha((root/source[name]).read_bytes())!=source[hash_key]:
                raise ValueError('Changed primary-source artifact: '+source[name])
    flat=lambda name:' '.join((root/name).read_text().split())
    original=flat('2018-17709-raw.txt').split('ANNEX C')[-1]
    clause=re.search(r'by inserting in lieu thereof: "(The additional duties imposed.*?9802\.00\.80\.)"',original)[1]
    correction=flat('2018-21303-page3-ocr.txt')
    old=re.search(r'by deleting: “(.*?)”',correction)[1]
    new=re.search(r'by inserting in lieu thereof: “(.*?)”',correction)[1]
    if clause.count(old)!=1:raise ValueError('Original Chapter 98 correction operand missing')
    corrected=clause.replace(old,new)
    policy=treatment(corrected,'section301')
    newer=flat('2024-21217-raw.txt')
    newer=re.search(r'The additional duties imposed by headings .*?do not apply.*?as described in heading 9802\.00\.80\.',newer)[0]
    if treatment(newer,'section301')!=policy:raise ValueError('Original note20/note31 valuation disagreement')
    maritime=flat('2025-19568-raw.txt')
    operation=re.search(r'Subdivision \(a\) of U.S. note 31.*?modified by deleting ‘‘(.*?)’’ wherever it appears and inserting ‘‘(.*?)’’ in lieu thereof',maritime)
    if not operation:raise ValueError('Missing original maritime target amendment')
    added=sorted(set(re.findall(r'9903\.\d{2}\.\d{2}',operation[2]))-set(re.findall(r'9903\.\d{2}\.\d{2}',operation[1])))
    return policy,review,dict(original_operand=old,corrected_operand=new,corrected_note20_clause=corrected,
        maritime_old=operation[1],maritime_new=operation[2],maritime_added_targets=added)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=False)
    deps=['src/section301_sources.py','src/section301_chapter98.py','src/chapter98_rules.py']
    hashes={f:sha((ROOT/f).read_bytes()) for f in deps}
    policy,review,operations=original_policy()
    revisions=(ROOT/'docs/audits/2026-10-23-motherduck/rebuild-revisions.txt').read_text().strip().split(',')
    reports=[]
    for rev in revisions:
        pdf=ROOT/f'data/us_notes/chapter99_{rev}.pdf';hts=ROOT/f'data/hts_archives/hts_{rev}.json'
        raw=subprocess.check_output(['pdftotext','-layout',str(pdf),'-']).decode();verify_revision_header(raw,rev)
        x=extract(raw,json.loads(hts.read_bytes()),rev);compiled=compile_valuations(x)
        for code,v in compiled['valuations'].items():
            if v['policy']!=policy:raise ValueError('Changed Chapter98 treatment requires review: '+rev+' '+code)
        maritime=[a for a in x['actions'] if a['program']=='maritime']
        if maritime and not set(operations['maritime_added_targets'])<=set(compiled['valuations']):
            raise ValueError('Maritime source targets do not reconcile')
        reports.append(dict(revision=rev,pdf_sha256=sha(pdf.read_bytes()),hts_sha256=sha(hts.read_bytes()),
            chapter98_provisions=len(x['chapter98_provisions']),valuation_count=len(compiled['valuations']),
            valuation_sha256=sha(json.dumps(compiled,sort_keys=True,separators=(',',':')).encode()),
            actions=[dict(code=a['reporting_code'],program=a['program'],clause=a['chapter98']) for a in x['actions']]))
        print(rev,len(compiled['valuations']),flush=True)
    if hashes!={f:sha((ROOT/f).read_bytes()) for f in deps}:raise ValueError('Source compiler changed during audit')
    raw=json.dumps(reports,sort_keys=True,separators=(',',':')).encode()
    (a.output/'revision-clauses.json.gz').write_bytes(gzip.compress(raw,mtime=0))
    (a.output/'report.json').write_text(json.dumps(dict(revision_count=len(reports),
        action_valuations=sum(r['valuation_count'] for r in reports),policy=policy,
        source_versions=hashes,primary_review=review,original_operations=operations,
        revision_clauses_sha256=sha(raw),timeseries_rebuilt=False,complete_legal_coverage=False),indent=2)+'\n')


if __name__=='__main__':main()
