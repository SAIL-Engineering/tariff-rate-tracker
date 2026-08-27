"""Every committed jurisdiction spec must load, validate, and reference real
files; ordering constraints are enforced at load time."""
import json
from pathlib import Path

import pytest

from conftest import AUTOMATION

import spec as spec_mod

SPEC_DIR = Path(__file__).parents[2] / "config" / "jurisdictions"


def _spec_files():
    return sorted(SPEC_DIR.glob("*.json"))


def test_spec_dir_has_specs():
    names = {p.name for p in _spec_files()}
    assert {"us.json", "ca.json"} <= names


@pytest.mark.parametrize("path", [p for p in _spec_files()
                                  if not p.name.endswith("_golden_queries.json")
                                  and p.name != "_schema.json"],
                         ids=lambda p: p.name)
def test_spec_validates(path, monkeypatch):
    monkeypatch.chdir(SPEC_DIR.parents[1])
    s = spec_mod.load_spec(path)
    assert s["code"].lower() == path.stem
    # referenced files exist
    for key in ("golden_queries",):
        for block in ("publish", "smoke"):
            v = (s.get(block) or {}).get(key)
            if v:
                assert Path(v).is_file(), f"{path.name}: {block}.{key} -> {v}"
    if s.get("registry"):
        assert Path(s["registry"]).is_file()


def test_ship_before_envvars_enforced(tmp_path, monkeypatch):
    monkeypatch.chdir(SPEC_DIR.parents[1])
    bad = json.loads((SPEC_DIR / "us.json").read_text())
    bad["steps"] = ["acquire", "build", "publish", "register", "envvars", "ship"]
    p = tmp_path / "us.json"
    p.write_text(json.dumps(bad))
    with pytest.raises(SystemExit, match="must precede"):
        spec_mod.load_spec(p)


def test_unknown_step_rejected(tmp_path, monkeypatch):
    monkeypatch.chdir(SPEC_DIR.parents[1])
    bad = json.loads((SPEC_DIR / "ca.json").read_text())
    bad["steps"] = ["acquire", "teleport"]
    p = tmp_path / "ca.json"
    p.write_text(json.dumps(bad))
    with pytest.raises(SystemExit, match="unknown steps"):
        spec_mod.load_spec(p)


def test_golden_query_files_wellformed():
    for p in SPEC_DIR.glob("*_golden_queries.json"):
        data = json.loads(p.read_text())
        assert data, p.name
        for item in data:
            assert item["query"] and len(item["expect_heading"]) == 4, (p.name, item)
