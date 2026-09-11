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


def test_notes_swap_prunes_only_its_own_family(monkeypatch):
    namespaces = {
        "us__2026_rev_18": 100,
        "us__2026_rev_18__section": 20,
        "us__2026_rev_18__chapter": 200,
        "us__2026_rev_16__gri": 16,
        "us__2026_rev_17__gri": 17,
        "us__2026_rev_18__gri": 18,
    }
    deleted = []
    monkeypatch.setattr(pinecone_sync, "index_host", lambda _index: "notes.host")
    monkeypatch.setattr(pinecone_sync, "list_namespaces", lambda _host: namespaces)
    monkeypatch.setattr(pinecone_sync, "cmd_upsert", lambda _args: None)
    monkeypatch.setattr(pinecone_sync, "cmd_verify", lambda _args: None)
    monkeypatch.setattr(
        pinecone_sync,
        "_request",
        lambda url, **kwargs: deleted.append((url, kwargs.get("method"))),
    )
    args = type("Args", (), {
        "index": "sail-hts-notes-dense",
        "namespace": "us__2026_rev_18__gri",
        "keep": 2,
    })()

    pinecone_sync.cmd_swap(args)

    assert deleted == [
        ("https://notes.host/namespaces/us__2026_rev_16__gri", "DELETE"),
    ]
