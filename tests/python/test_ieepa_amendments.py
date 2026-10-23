import re
from pathlib import Path
import sys
import pytest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))
import ieepa_amendments as parser


def test_primary_country_amendment_chronology():
    amendments=parser.load_amendments()
    assert [(a['effective_from'],[x['ch99_code'] for x in a['actions']]) for a in amendments]==[
        ('2025-08-07T00:01:00-04:00',['9903.02.73']),
        ('2025-11-14T00:01:00-05:00',['9903.02.80']),
        ('2025-11-14T00:01:00-05:00',['9903.02.83','9903.02.88'])]
    assert all(x['rate']==.15 for a in amendments for x in a['actions'])
    assert all(len(a['source_scope_sha256'])==64 for a in amendments)
    assert not any(x['ch99_code'].startswith('9903.76') for a in amendments for x in a['actions'])


@pytest.mark.parametrize('mutation',[
    lambda s:s.replace('Annex I','Unidentified annex'),
    lambda s:re.sub(r'12:01 a\.m\.\s+eastern time','noon',s),
    lambda s:re.sub(r'is\s+(?:hereby )?terminated','remains active',s),
    lambda s:re.sub(r'less than 15\s+percent','at any rate',s),
])
def test_unknown_legal_grammar_fails(mutation):
    doc,start,end=parser.LOCATORS[0]
    text=(ROOT/'resources/legal_evidence'/doc/'notice.txt').read_text()
    changed=mutation(text)
    assert changed!=text
    with pytest.raises(ValueError):parser.extract_country_amendment(changed,start,end)
