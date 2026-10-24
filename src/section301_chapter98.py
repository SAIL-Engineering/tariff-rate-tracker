"""Compile only the Chapter 98 effects expressly attached to a 301 action.

Source extraction remains separate. The R reference build uses this adapter to
reuse the same valuation expression compiler as Sections 122 and 338. An absent
clause cannot be replaced with an assumption about another investigation.
"""
import json
import sys
from chapter98_rules import compile_valuation
from section232_note16_rules import fact


def compile_valuations(extraction):
    ids=['USITC-'+extraction['revision']+s for s in ('-chapter99','-hts')]
    hts=[{'htsno':c[:4]+'.'+c[4:6]+'.'+c[6:]} for c in extraction['chapter98_provisions']]
    definitions={}
    def define(name,label,kind='boolean',description=None,choices=None):
        d=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':d.update(minimum=0,unit='USD')
        if description:d['description']=description
        if choices:d['enum']=choices
        if name in definitions and definitions[name]!=d:raise ValueError('Conflicting Chapter 98 fact')
        definitions[name]=d
        return fact(name)
    valuations={}
    for action in extraction['actions']:
        clause=action.get('chapter98')
        if clause is None:continue
        code=action['reporting_code']
        if code not in clause['target_reporting_codes']:raise ValueError('Chapter 98 target mismatch')
        valuations[code]=compile_valuation(clause['source_text'],hts,define,
            {'claim':'CHAPTER_98'},fact('customs_value'),family='section301')
    return dict(valuations=valuations,fact_definitions=definitions)


if __name__=='__main__':
    with open(sys.argv[1]) as f:extraction=json.load(f)
    with open(sys.argv[2],'w') as f:json.dump(compile_valuations(extraction),f,sort_keys=True)
