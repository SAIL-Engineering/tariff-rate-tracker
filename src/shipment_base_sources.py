"""Extract complete base-duty text and its actual classification ancestor.

No economic rate, AVE, quantity, share or fallback zero is used. The JSON indent
tree is traversed for every record, including blank-rate structural records, so
an earlier sibling cannot supply the next branch's duty. Interpretation of the
complete expression is a separate compiler step.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re

COLUMNS={'general':'general', 'column2':'other', 'special':'special'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def extract_rows(rows):
    if not isinstance(rows,list):
        raise ValueError('Expected native HTS record array')
    native_tens={r.get('htsno','').replace('.','') for r in rows
                 if re.fullmatch(r'\d{4}\.\d{2}\.\d{2}\.\d{2}',r.get('htsno',''))}
    tens_parents={c[:8] for c in native_tens}
    stack=[]
    products={}
    for index,row in enumerate(rows):
        if not isinstance(row,dict):
            raise ValueError('Invalid native HTS record')
        indent=row.get('indent','0')
        if indent is None or str(indent).strip()=='':
            indent='0'
        if not re.fullmatch(r'\d+',str(indent)):
            raise ValueError('Unrecognized HTS indent')
        indent=int(indent)
        # This happens even when the new branch has no published rate text.
        while stack and stack[-1]['indent']>=indent:
            stack.pop()
        printed=row.get('htsno','') or ''
        if printed and not re.fullmatch(r'\d{2}(?:\d{2}(?:\.\d{2}){0,3})?',printed):
            raise ValueError('Unrecognized HTS identifier: '+printed)
        code=printed.replace('.','')
        nearest=code or (stack[-1]['nearest_code'] if stack else '')
        resolved={}
        for name,key in COLUMNS.items():
            value=row.get(key,'')
            if value is None:value=''
            if not isinstance(value,str):
                raise ValueError('Nontext base-duty expression')
            if value.strip():
                resolved[name]=dict(expression=value.strip(),source_code=nearest,
                    source_row_index=index,source_indent=indent,
                    footnotes=copy.deepcopy(row.get('footnotes') or []))
            else:
                source=next((p['columns'][name] for p in reversed(stack)
                             if p['columns'][name]['expression'] is not None),None)
                resolved[name]=copy.deepcopy(source) if source else dict(expression=None,source_code=None,
                    source_row_index=None,source_indent=None,footnotes=[])
        record=dict(indent=indent,nearest_code=nearest,columns=resolved,
            printed_code=code,description=row.get('description',''))
        stack.append(record)
        if not code or not 1<=int(code[:2])<=98:
            continue
        if len(code)==10:
            hts10=code
        elif len(code)==8 and code not in tens_parents:
            # Exactly one canonical Census identity for a native HTS8 leaf.
            # Never create this record for a parent with statistical children.
            hts10=code+'00'
        else:
            continue
        errors=[]
        for name in COLUMNS:
            column=resolved[name]
            owner=column['source_code']
            if column['expression'] is not None and (not owner or not hts10.startswith(owner)):
                column['rejected_source_code']=owner
                column['rejected_expression']=column['expression']
                column['expression']=None
                errors.append('unrelated_'+name+'_ancestor')
            elif column['expression'] is None:
                errors.append('missing_'+name+'_expression')
        product=dict(hts10=hts10,native_code=code,native_grain=len(code),
            description=row.get('description',''),**resolved,
            classification_path=[dict(code=p['printed_code'],description=p['description']) for p in stack],
            status='source_extracted' if resolved['general']['expression'] is not None else 'unresolved_source',
            source_errors=errors,observation_rows=[index])
        if code.startswith('98'):
            # A printed special-classification expression is not evidence that
            # its entitlement or every additional-program interaction is met.
            product['source_role']='conditional_special_classification'
        if hts10 in products:
            old=products[hts10]
            def semantics(p):
                return (p['native_code'],p['description'],[(p[c]['expression'],p[c]['source_code'],p[c]['footnotes']) for c in COLUMNS])
            if semantics(old)!=semantics(product):
                raise ValueError('Conflicting duplicate base-duty record: '+hts10)
            old['observation_rows'].append(index)
        else:
            products[hts10]=product
    return dict(products=[products[k] for k in sorted(products) if not k.startswith('98')],
        special_classifications=[products[k] for k in sorted(products) if k.startswith('98')])


def extract(path: Path,revision: str):
    if not re.fullmatch(r'202[56]_(?:basic|rev_\d+)',revision):
        raise ValueError('Identified 2025/2026 revision required')
    if path.name!='hts_'+revision+'.json':
        raise ValueError('Base source filename does not match requested revision')
    data=path.read_bytes()
    x=extract_rows(json.loads(data))
    release=revision.replace('_rev_','HTSRev').replace('_basic','HTSBasic')
    x.update(contract_version='sail.shipment-base-extraction/v1',revision=revision,
        extractor_sha256=sha(Path(__file__).read_bytes()),
        source=dict(path=str(path.resolve()),sha256=sha(data),
            url=f'https://hts.usitc.gov/reststop/exportList?release={release}&exportFormat=JSON',
            citation=f'USITC {revision}, native base-duty columns and classification hierarchy'))
    return x


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--hts',type=Path,required=True)
    parser.add_argument('--revision',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    args.output.write_text(json.dumps(extract(args.hts,args.revision),indent=2)+'\n')


if __name__=='__main__':
    main()
