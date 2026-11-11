"""SG, MY and VN publish the legal notes their parsers wrote to the notes index,
as <namespace>__<family>, the names sail-gtx searches. Everything the publish
step will check at run time -- the files, the manifest record counts and the
golden queries -- is checked here first."""
import copy
import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "hts_automation"))

import pinecone_sync                                    # noqa: E402
import refresh                                          # noqa: E402
from spec import SpecError, load_spec, validate_spec    # noqa: E402
from steps import step_consumes                         # noqa: E402

REVISIONS = {"SG": "2022_rev_101", "MY": "2025_rev_1101", "VN": "2026_rev_405"}


@pytest.fixture(autouse=True)
def _repo_root(monkeypatch):
    monkeypatch.chdir(ROOT)


def spec(cc):
    return load_spec(ROOT / "config" / "jurisdictions" / f"{cc.lower()}.json")


def families(s):
    return s["notes"].get("families", ["gri", "section", "chapter"])


def notes_path(cc, kind):
    stem = f"{cc.lower()}_{REVISIONS[cc]}"
    return ROOT / "data" / "hts_notes" / stem / f"{stem}.notes.{kind}"


@pytest.mark.parametrize("cc", sorted(REVISIONS))
def test_notes_are_published_before_the_revision_is_registered(cc):
    steps = spec(cc)["steps"]
    assert steps.index("publish") < steps.index("publish_notes") < steps.index("register")


def test_vietnam_publishes_no_gri_family():
    s = spec("VN")
    assert families(s) == ["section", "chapter"]
    assert "notes_gri_jsonl" not in step_consumes(s, "publish_notes")
    assert set(step_consumes(spec("SG"), "publish_notes")) == {
        "notes_manifest", "notes_gri_jsonl", "notes_section_jsonl", "notes_chapter_jsonl"}


@pytest.mark.parametrize("cc", sorted(REVISIONS))
def test_each_family_file_holds_what_its_manifest_declares(cc):
    manifest = json.loads(notes_path(cc, "manifest.json").read_text(encoding="utf-8"))
    by_kind = manifest["counts"]["by_kind"]
    for family in families(spec(cc)):
        lines = notes_path(cc, f"{family}.jsonl").read_text(encoding="utf-8").splitlines()
        expected = sum(int(by_kind.get(k, 0)) for k in pinecone_sync.FAMILY_KINDS[family])
        assert len(lines) == expected, (cc, family)
    # every kind in the manifest is counted in exactly one published family
    counted = {k for f in families(spec(cc)) for k in pinecone_sync.FAMILY_KINDS[f]}
    assert set(by_kind) <= counted, set(by_kind) - counted


@pytest.mark.parametrize("cc", sorted(REVISIONS))
def test_golden_queries_cover_every_family_and_name_real_notes(cc):
    s = spec(cc)
    queries = json.loads((ROOT / s["notes"]["golden_queries"]).read_text(encoding="utf-8"))
    for family in families(s):
        cites = {json.loads(l)["cite_id"] for l in
                 notes_path(cc, f"{family}.jsonl").read_text(encoding="utf-8").splitlines()}
        mine = [q for q in queries if q["family"] == family]
        assert mine, (cc, family)
        assert all(q["expect_cite_id"] in cites for q in mine), (cc, family)


def test_vietnam_publish_notes_runs_two_families(monkeypatch):
    calls = []
    monkeypatch.setattr(refresh, "run", lambda cmd, exit_code: calls.append(cmd))
    monkeypatch.setenv("PINECONE_NOTES_INDEX", refresh.DEFAULT_NOTES_INDEX)
    ctx = {"namespace": "vn__2026_rev_405", "notes_manifest": "m.json",
           "notes_section_jsonl": "s.jsonl", "notes_chapter_jsonl": "c.jsonl"}
    refresh.do_publish_notes(spec("VN"), ctx, type("A", (), {"keep": None})())
    assert [c[c.index("--namespace") + 1] for c in calls] == [
        "vn__2026_rev_405__section", "vn__2026_rev_405__chapter"]
    assert all(c[c.index("--index") + 1] == "sail-hts-notes-dense" for c in calls)


def test_spec_rules(monkeypatch):
    base = spec("VN")
    bad = copy.deepcopy(base)
    bad["steps"].insert(bad["steps"].index("build") + 1, "notes")
    with pytest.raises(SpecError, match="US-only"):
        validate_spec(bad)
    bad = copy.deepcopy(base)
    bad["notes"]["families"] = ["gri", "gri"]
    with pytest.raises(SpecError, match="families"):
        validate_spec(bad)
    bad = copy.deepcopy(base)
    bad["steps"].remove("publish_notes")
    bad["steps"].append("publish_notes")
    with pytest.raises(SpecError, match="must precede"):
        validate_spec(bad)


# ── the published records: US shape, and the defects fixed on 2026-11-11 ─────

US_FIELDS = set(__import__("notes_contract").PINECONE_FIELDS)


def records(cc):
    out = {}
    for path in sorted(notes_path(cc, "x").parent.glob("*.notes.*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            r = json.loads(line)
            out[r["cite_id"]] = r
    return out


@pytest.mark.parametrize("cc", sorted(REVISIONS))
def test_records_have_the_us_shape(cc):
    recs = records(cc)
    ids = [r["_id"] for r in recs.values()]
    assert len(ids) == len(set(ids))                   # Pinecone keys by _id
    for r in recs.values():
        assert set(r) <= US_FIELDS and None not in r.values(), r["cite_id"]
        if r["kind"] == "section_note":
            assert r["chapter"], r["cite_id"]
    assert any(r.get("paragraph") for r in recs.values())
    assert not [c for c in recs if c[-1] in "bcd" and c[:-1] in recs]   # no N-48-1b


@pytest.mark.parametrize("cc", ["SG", "MY"])
def test_gri_paragraphs_match_the_us(cc):
    gri = sorted(c for c, r in records(cc).items() if r["kind"] == "gri" and r.get("paragraph"))
    assert gri == ["GRI-2(a)", "GRI-2(b)", "GRI-3(a)", "GRI-3(b)", "GRI-3(c)",
                   "GRI-5(a)", "GRI-5(b)"]


def test_vietnam_keeps_body_text_and_note_starts():
    vn = records("VN")
    assert "Rolled, extruded, drawn or forged products" in vn["SN-XV-9"]["chunk_text"]
    assert vn["N-9-1"]["chunk_text"].endswith("classified in heading 21.03.")
    assert vn["SN-XVI-6"]["chunk_text"].startswith("(A) Throughout the Nomenclature")
    assert "weighing not more than 80 g/m2" in vn["N-48-5"]["chunk_text"]
    assert not vn["N-1-1"]["chunk_text"].startswith("1.")


def test_singapore_chapter_4_notes_are_separate():
    sg = records("SG")
    assert {f"N-4-{n}" for n in range(1, 7)} <= set(sg)
    assert sg["N-4-1"]["chunk_text"].endswith("skimmed milk.")
    assert {"SHN-4-1", "SHN-4-2"} <= set(sg)


def test_malaysia_repairs():
    my = records("MY")
    assert "(p) Original sculptures or statuary" in my["N-71-3(p)"]["chunk_text"]
    assert "Original sculptures" not in my["N-71-3(o)"]["chunk_text"]
    assert "(p) Original sculptures" in my["N-71-3"]["chunk_text"]
    assert "one (p) hundred" not in my["N-71-3"]["chunk_text"]
    assert "Light oils" in my["NN-27-1"]["chunk_text"] or "Lights oils" in my["NN-27-1"]["chunk_text"]
