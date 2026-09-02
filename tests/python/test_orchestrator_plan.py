"""Planner logic: pure functions, no network, no secrets."""
import json
from pathlib import Path

import pytest

import spec as spec_mod
from steps import REGISTRY, step_consumes, producer_of

SPEC_DIR = Path(__file__).parents[2] / "config" / "jurisdictions"


def _load(name, monkeypatch):
    monkeypatch.chdir(SPEC_DIR.parents[1])
    return spec_mod.load_spec(SPEC_DIR / name)


def _plan(spec, **kw):
    # import inside: refresh.py inserts sys.path and chdirs only under main()
    import refresh
    return refresh.plan_steps(spec, kw.get("from_step"), kw.get("only"),
                              kw.get("until"), kw.get("dry_run", False))


def test_us_full_plan(monkeypatch):
    s = _load("us.json", monkeypatch)
    assert _plan(s) == ["acquire", "build", "verify", "publish", "register",
                        "ship", "envvars", "smoke"]


def test_ca_full_plan(monkeypatch):
    s = _load("ca.json", monkeypatch)
    assert _plan(s) == ["acquire", "build", "verify", "publish", "register", "ship"]


def test_dry_run_drops_external_writes(monkeypatch):
    s = _load("ca.json", monkeypatch)
    assert _plan(s, dry_run=True) == ["acquire", "build", "verify", "ship"]
    # ship still runs (it passes --dry-run through to sail_gtx_commit.py)


def test_from_step_by_name(monkeypatch):
    s = _load("ca.json", monkeypatch)
    assert _plan(s, from_step="publish") == ["publish", "register", "ship"]


def test_from_step_by_index_is_jurisdiction_local(monkeypatch):
    s = _load("ca.json", monkeypatch)
    # 1-based into CA's own list: 3 = verify
    assert _plan(s, from_step="3") == ["verify", "publish", "register", "ship"]


def test_only_and_until(monkeypatch):
    s = _load("us.json", monkeypatch)
    assert _plan(s, only="publish") == ["publish"]
    assert _plan(s, until="build") == ["acquire", "build"]


def test_required_env_is_union_over_scheduled(monkeypatch):
    import refresh
    s = _load("ca.json", monkeypatch)
    # a CA dry-run needs NO secrets except the ship PAT
    env = refresh.required_env(s, _plan(s, dry_run=True))
    assert env == ["SAIL_GTX_REPO_PAT", "SAIL_GTX_PRODUCTION_BRANCH"]
    # the full CA run needs exactly pinecone + supabase + ship
    env_full = set(refresh.required_env(s, _plan(s)))
    assert env_full == {"PINECONE_API_KEY", "SUPABASE_URL",
                        "SUPABASE_SERVICE_ROLE_KEY", "SAIL_GTX_REPO_PAT",
                        "SAIL_GTX_PRODUCTION_BRANCH"}


def test_preflight_flags_missing_artifacts(monkeypatch, tmp_path):
    import refresh
    s = _load("ca.json", monkeypatch)
    monkeypatch.chdir(tmp_path)  # nothing on disk
    ctx = {"source_csv": "nope.csv", "corpus_jsonl": "nope.jsonl",
           "codes_json": "nope.codes.json", "manifest_json": "nope.manifest.json",
           "coverage_json": "nope.coverage.json", "diff_json": "nope.diff.json",
           "dataset_json": "", "env_snapshot": "/tmp/x.json"}
    errors = refresh.preflight_artifacts(s, ["publish", "register", "ship"], ctx)
    # publish consumes corpus_jsonl+manifest (producer build not scheduled),
    # ship consumes codes_json
    joined = "\n".join(errors)
    assert "corpus_jsonl" in joined and "codes_json" in joined
    # ...and scheduling build clears those complaints about build's products
    errors2 = refresh.preflight_artifacts(
        s, ["build", "verify", "publish", "register", "ship"], ctx)
    joined2 = "\n".join(errors2)
    assert "corpus_jsonl" not in joined2 and "codes_json" not in joined2
    # but build itself needs the source now
    assert "source_csv" in joined2


def test_us_ship_consumes_dataset(monkeypatch):
    s = _load("us.json", monkeypatch)
    assert "dataset_json" in step_consumes(s, "ship")
    ca = _load("ca.json", monkeypatch)
    assert "dataset_json" not in step_consumes(ca, "ship")


def test_ship_consumes_all_also_artifacts(monkeypatch):
    """A missing Explorer dataset or duty-rates dir must be a PLAN-time error,
    not a failure four steps into a run after a Pinecone publish."""
    s = _load("eu.json", monkeypatch)
    consumed = step_consumes(s, "ship")
    assert {"codes_json", "explorer_json", "rates_dir",
            "rates_index", "treatments_json"} <= set(consumed)


def test_build_produces_rates_when_spec_enables(monkeypatch):
    from steps import step_produces
    eu = _load("eu.json", monkeypatch)
    assert {"rates_dir", "rates_index", "treatments_json",
            "explorer_json"} <= set(step_produces(eu, "build"))
    us = _load("us.json", monkeypatch)
    assert "rates_dir" not in step_produces(us, "build")
    assert "explorer_json" not in step_produces(us, "build")
    # so the preflight maps them to build
    assert producer_of(eu, "rates_dir") == "build"


def test_producer_map(monkeypatch):
    s = _load("ca.json", monkeypatch)
    assert producer_of(s, "corpus_jsonl") == "build"
    assert producer_of(s, "source_csv") == "acquire"
    assert producer_of(s, "diff_json") == "verify"


def test_language_artifacts_have_build_as_producer(monkeypatch):
    """CH/EU/KR ship per-language corpora + Explorer datasets; the preflight
    must know build produces them or a full rollout dies at plan time."""
    from steps import step_produces
    ch = _load("ch.json", monkeypatch)
    produced = set(step_produces(ch, "build"))
    for lang in ("de", "fr", "it"):
        assert f"corpus_jsonl_{lang}" in produced
        assert f"explorer_json_{lang}" in produced
        assert producer_of(ch, f"explorer_json_{lang}") == "build"


def test_rates_only_ship_consumes_only_duty_artifacts(monkeypatch):
    """A rates-only refresh never rebuilds the corpus/Explorer artifacts, so
    the preflight must not demand them (CH 2026-09-02 regression)."""
    ch = _load("ch.json", monkeypatch)
    full = set(step_consumes(ch, "ship"))
    reduced = set(step_consumes(ch, "ship", rates_only=True))
    assert "explorer_json_de" in full
    assert reduced <= {"rates_dir", "rates_index", "treatments_json"} | set(
        REGISTRY["ship"].consumes)
    assert "explorer_json_de" not in reduced
    assert "explorer_json" not in reduced
    assert {"rates_dir", "rates_index", "treatments_json"} <= reduced
