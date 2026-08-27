"""Chapters config files: no duplicate chapter keys, loadable, sane."""
import json
from pathlib import Path

import pytest

import build_hts_corpus as bhc
from conftest import AUTOMATION


def _chapters_files():
    return sorted(AUTOMATION.glob("chapters*.json"))


def test_chapters_files_exist():
    names = {p.name for p in _chapters_files()}
    assert {"chapters.json", "chapters_ca.json"} <= names


@pytest.mark.parametrize("path", _chapters_files(), ids=lambda p: p.name)
def test_no_duplicate_chapter_keys(path):
    """chapters.json shipped with chapter 99 twice and dict last-wins hid it.
    load_chapters now raises; this test keeps the config files clean."""
    data = json.loads(path.read_text(encoding="utf-8"))
    seen = set()
    for c in data:
        assert c["chapter"] not in seen, f"duplicate chapter {c['chapter']} in {path.name}"
        seen.add(c["chapter"])


@pytest.mark.parametrize("path", _chapters_files(), ids=lambda p: p.name)
def test_load_chapters_returns_full_records(path):
    m = bhc.load_chapters(path)
    assert m, path.name
    for ch, rec in m.items():
        assert isinstance(rec, dict) and rec.get("description"), (path.name, ch)


def test_load_chapters_raises_on_duplicate(tmp_path):
    p = tmp_path / "dup.json"
    p.write_text(json.dumps([
        {"chapter": "01", "description": "a"},
        {"chapter": "01", "description": "b"},
    ]))
    with pytest.raises(SystemExit, match="duplicate chapter"):
        bhc.load_chapters(p)
