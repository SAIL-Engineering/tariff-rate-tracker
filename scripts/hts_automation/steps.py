#!/usr/bin/env python3
"""Step registry for refresh.py: what each step consumes, produces, and needs.

Declaring artifacts and env vars per step is what makes the orchestrator
correct for ANY subset of steps, any jurisdiction:

  * the artifact preflight ("--from-step publish skips the step that produces
    X, which publish consumes") is one generic loop instead of the hand-
    unrolled require_file block run_locally.sh carried, and
  * required env vars are the union over the steps that will actually run,
    instead of an unconditional 13-var hard fail that demanded Railway
    credentials for a --dry-run corpus build.

Artifact keys are logical names resolved against the run context (RunCtx):
  source_csv, dataset_json, corpus_jsonl, codes_json, manifest_json,
  coverage_json, diff_json, env_snapshot
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class StepDef:
    name: str
    consumes: tuple = ()
    produces: tuple = ()
    requires_env: tuple = ()
    # exit code when this step fails (preserves the historical per-phase codes)
    exit_code: int = 1
    # skipped entirely under --dry-run (vs run with a --dry-run flag)
    skip_on_dry_run: bool = False


REGISTRY: dict[str, StepDef] = {s.name: s for s in [
    StepDef("acquire",
            produces=("source_csv",),
            exit_code=1),
    StepDef("build",
            consumes=("source_csv",),
            produces=("corpus_jsonl", "codes_json", "manifest_json",
                      "coverage_json"),
            exit_code=2),
    StepDef("verify",
            consumes=("codes_json", "corpus_jsonl"),
            produces=("diff_json",),
            exit_code=2),
    StepDef("publish",
            consumes=("corpus_jsonl", "manifest_json"),
            requires_env=("PINECONE_API_KEY",),
            exit_code=3,
            skip_on_dry_run=True),
    StepDef("register",
            requires_env=("SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"),
            exit_code=4,
            skip_on_dry_run=True),
    StepDef("ship",
            consumes=("codes_json",),   # dataset_json added dynamically when shipped
            requires_env=("SAIL_GTX_REPO_PAT", "SAIL_GTX_PRODUCTION_BRANCH"),
            exit_code=5),
    StepDef("envvars",
            requires_env=("RAILWAY_TOKEN", "RAILWAY_PROJECT_ID", "RAILWAY_SERVICE_ID",
                          "RAILWAY_ENVIRONMENT_ID", "VERCEL_TOKEN", "VERCEL_PROJECT_ID"),
            produces=("env_snapshot",),
            exit_code=6,
            skip_on_dry_run=True),
    StepDef("smoke",
            requires_env=("SAIL_GTX_HEALTHCHECK_URL", "SAIL_GTX_API_BASE",
                          "PINECONE_API_KEY", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"),
            exit_code=9,
            skip_on_dry_run=True),
]}


def step_consumes(spec: dict, name: str) -> tuple:
    """A step's consumed artifacts, spec-adjusted:
      - US ship also ships the raw dataset;
      - EVERY ship.also `from` key is consumed, so the preflight catches a
        missing Explorer dataset or duty-rates dir at plan time instead of
        four steps into a run (after a Pinecone publish)."""
    base = REGISTRY[name].consumes
    if name == "ship":
        ship = spec.get("ship") or {}
        extra = tuple(a["from"] for a in ship.get("also", [])
                      if a.get("from") and a["from"] not in base)
        if ship.get("source") == "dataset_json":
            extra = ("dataset_json",) + extra
        return base + extra
    return base


def step_produces(spec: dict, name: str) -> tuple:
    """A step's produced artifacts, spec-adjusted: `build` also produces the
    Explorer dataset (non-US) and the duty-rate outputs when the spec enables
    them."""
    base = REGISTRY[name].produces
    if name == "build":
        if spec.get("source_format", "usitc") != "usitc":
            base = base + ("explorer_json",)
        if spec.get("duty_rates"):
            base = base + ("rates_dir", "rates_index", "treatments_json")
        return tuple(dict.fromkeys(base))
    return base


def producer_of(spec: dict, key: str) -> str | None:
    if key == "dataset_json" or key == "source_csv":
        return "acquire"
    for s in spec["steps"]:
        if key in step_produces(spec, s):
            return s
    return None
