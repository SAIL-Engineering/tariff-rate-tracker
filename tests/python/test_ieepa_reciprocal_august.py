"""A matching text checksum is not proof that the text came from its PDF."""
import json
from pathlib import Path
import shutil
import sys
import pytest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'src'))
import ieepa_reciprocal_august as m
from section301_sources import sha


def test_changed_annex_text_with_a_recomputed_pin_cannot_add_an_uncompiled_condition(tmp_path,monkeypatch):
    source=ROOT/'resources/legal_evidence/2025-15010'
    folder=tmp_path/'resources/legal_evidence/2025-15010';folder.mkdir(parents=True)
    for name in ('white-house-annex-ii.txt','white-house-annex-ii.pdf','white-house-annex-ii.source.json'):
        shutil.copyfile(source/name,folder/name)
    archive=tmp_path/'data/hts_archives';archive.mkdir(parents=True)
    shutil.copyfile(ROOT/'data/hts_archives/hts_2025_rev_18.json',archive/'hts_2025_rev_18.json')
    text=folder/'white-house-annex-ii.txt'
    text.write_text(text.read_text().replace('Except for goods loaded onto a','Except for qualifying goods loaded onto a',1))
    pin=folder/'white-house-annex-ii.source.json';meta=json.loads(pin.read_text());meta['text_sha256']=sha(text.read_bytes());pin.write_text(json.dumps(meta))
    monkeypatch.setattr(m,'ROOT',tmp_path)
    with pytest.raises(ValueError,match='PDF|semantic'):
        m.load_august_country_policy()
