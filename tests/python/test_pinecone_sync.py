from __future__ import annotations

import json

import pinecone_sync


def test_every_subcommand_accepts_an_explicit_index():
    parser = pinecone_sync.build_parser()
    cases = [
        ["list", "--index", "notes"],
        ["upsert", "--index", "notes", "--jsonl", "x.jsonl", "--namespace", "x"],
        ["verify", "--index", "notes", "--namespace", "x"],
        ["delete", "--index", "notes", "--namespace", "x"],
        ["swap", "--index", "notes", "--jsonl", "x.jsonl", "--namespace", "x"],
    ]
    for argv in cases:
        assert parser.parse_args(argv).index == "notes"


def test_notes_goldens_filter_by_family(tmp_path):
    path = tmp_path / "goldens.json"
    path.write_text(json.dumps([
        {"family": "gri", "query": "unfinished article", "expect_cite_id": "GRI-2(a)"},
        {"family": "chapter", "query": "toy blocks", "expect_cite_id": "N-95-1"},
    ]))

    assert pinecone_sync.load_golden_queries(str(path), "gri") == [
        ("unfinished article", "cite_id", "GRI-2(a)"),
    ]


def test_index_host_uses_the_explicit_name(monkeypatch):
    urls = []
    monkeypatch.setattr(
        pinecone_sync,
        "_request",
        lambda url, **_kwargs: urls.append(url) or {"host": "notes.example"},
    )

    assert pinecone_sync.index_host("sail-hts-notes-dense") == "notes.example"
    assert urls == ["https://api.pinecone.io/indexes/sail-hts-notes-dense"]
