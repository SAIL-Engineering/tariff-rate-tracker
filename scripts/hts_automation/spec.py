#!/usr/bin/env python3
"""Jurisdiction spec loading and validation for refresh.py.

A spec (config/jurisdictions/<jur>.json) declares WHAT a jurisdiction's rollout
looks like; steps.py declares HOW each step runs. Keeping the two apart is the
point: adding a jurisdiction is a new JSON file, not a new shell script.

Specs are JSON, not YAML, deliberately: every script in this pipeline runs on a
bare python3 + requests, and the manual fallback path must too. `_comment*`
keys are ignored everywhere.
"""
from __future__ import annotations

import json
from pathlib import Path

VALID_STEPS = ("acquire", "build", "verify", "publish", "register", "ship",
               "envvars", "smoke")

# Ordering constraints, enforced at load time rather than trusted to comments.
# ship MUST precede envvars: the server asserts the dataset exists at boot, so
# flipping the env var before the file lands fails the redeploy.
MUST_PRECEDE = [("ship", "envvars"), ("build", "publish"), ("publish", "register"),
                ("build", "verify"), ("verify", "publish"), ("acquire", "build")]

REQUIRED_KEYS = ("code", "name", "tariff_schedule_name", "acquire",
                 "source_format", "chapters_file", "max_depth",
                 "namespace_pattern", "stem_pattern", "steps")


class SpecError(SystemExit):
    def __init__(self, msg: str):
        super().__init__(f"SPEC ERROR: {msg}")


def _strip_comments(obj):
    if isinstance(obj, dict):
        return {k: _strip_comments(v) for k, v in obj.items()
                if not k.startswith("_comment")}
    if isinstance(obj, list):
        return [_strip_comments(v) for v in obj]
    return obj


def load_spec(path: Path) -> dict:
    with path.open(encoding="utf-8") as fh:
        spec = _strip_comments(json.load(fh))
    validate_spec(spec, path)
    return spec


def validate_spec(spec: dict, path: Path | None = None) -> None:
    where = f" in {path}" if path else ""
    for key in REQUIRED_KEYS:
        if key not in spec:
            raise SpecError(f"missing required key {key!r}{where}")
    code = spec["code"]
    if not (isinstance(code, str) and len(code) == 2 and code.isupper()):
        raise SpecError(f"code must be 2 uppercase letters, got {code!r}{where}")

    steps = spec["steps"]
    unknown = [s for s in steps if s not in VALID_STEPS]
    if unknown:
        raise SpecError(f"unknown steps {unknown}{where}; valid: {list(VALID_STEPS)}")
    if len(set(steps)) != len(steps):
        raise SpecError(f"duplicate steps in {steps}{where}")
    for a, b in MUST_PRECEDE:
        if a in steps and b in steps and steps.index(a) > steps.index(b):
            raise SpecError(f"step {a!r} must precede {b!r}{where}")

    for step in steps:
        if step in ("verify", "publish", "register", "ship", "envvars", "smoke"):
            # per-step config blocks are optional except where a template is
            # structurally required
            pass
    if "ship" in steps:
        ship = spec.get("ship") or {}
        if not ship.get("dest_path") and not ship.get("also"):
            raise SpecError(f"ship step declared but ships nothing{where}")

    chapters = Path(spec["chapters_file"])
    if not chapters.exists():
        raise SpecError(f"chapters_file {chapters} does not exist{where}")


def render(template: str, ctx: dict) -> str:
    """Expand {year}/{number}/{revision}/{effective_date}/... placeholders."""
    try:
        return template.format(**ctx)
    except KeyError as e:
        raise SpecError(f"template {template!r} needs unknown key {e}")


def spec_path_for(jurisdiction: str) -> Path:
    return Path("config/jurisdictions") / f"{jurisdiction.lower()}.json"
