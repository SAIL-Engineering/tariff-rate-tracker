#!/usr/bin/env python3
"""refresh.py — jurisdiction-driven HTS corpus rollout.

One orchestrator for every jurisdiction, replacing run_locally.sh (US) and
refresh_ca.sh (CA), which remain as thin wrappers. WHAT to run comes from
config/jurisdictions/<jur>.json; HOW each step runs is here + steps.py.

  refresh.py --jurisdiction US                        # latest revision
  refresh.py --jurisdiction US --revision 2026_rev_8
  refresh.py --jurisdiction CA --dry-run              # build + report, no writes
  refresh.py --jurisdiction CA --from-step publish    # resume a broken run
  refresh.py --jurisdiction DO --acquire-adapter manual --source path.csv \
             --effective-date 2026-01-01
  refresh.py --jurisdiction US --plan-only            # show the plan and exit

--from-step accepts a step name (or a 1-based integer into THIS jurisdiction's
step list, printed by --plan-only). The read-only resolve always runs so a
resumed run has the revision facts; artifacts that skipped steps would have
produced must still exist — verified up front, generically.

Exit codes: 0 ok · 1 config/args · 2 build/verify · 3 publish · 4 register ·
5 ship · 6 envvars · 9 smoke (env snapshot is reverted first).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

from acquire import get_adapter                       # noqa: E402
from spec import load_spec, render, spec_path_for     # noqa: E402
from steps import REGISTRY, step_consumes, producer_of  # noqa: E402


def log(msg: str) -> None:
    print(f"\n\033[1;36m[refresh]\033[0m {msg}", flush=True)


def run(cmd: list[str], exit_code: int) -> None:
    print("  $ " + " ".join(str(c) for c in cmd), flush=True)
    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        sys.exit(exit_code if proc.returncode == 0 else
                 (proc.returncode if exit_code == 0 else exit_code))


# ─── Context ─────────────────────────────────────────────────────────

class RunCtx(dict):
    """Template context + logical-artifact resolution."""

    def artifact(self, key: str) -> Path:
        return Path(self[key])


def build_ctx(spec: dict, res) -> RunCtx:
    ctx = RunCtx()
    ctx.update({
        "jur": spec["code"], "jur_lower": spec["code"].lower(),
        "year": res.year, "number": res.rev_num, "revision": res.rev_id,
        "effective_date": res.effective_date,
        "effective_date_label": res.effective_date_label,
    })
    stem = render(spec["stem_pattern"], ctx)
    ctx["stem"] = stem
    ctx["namespace"] = render(spec["namespace_pattern"], ctx)
    ctx["source_csv"] = res.source_csv
    ctx["dataset_json"] = res.source_json or ""
    ctx["corpus_jsonl"] = f"{stem}.jsonl"
    ctx["codes_json"] = f"{stem}.codes.json"
    ctx["manifest_json"] = f"{stem}.manifest.json"
    ctx["coverage_json"] = f"{stem}.coverage.json"
    ctx["diff_json"] = f"{stem}.diff.json"
    # SPA HTS Explorer dataset (jurisdiction-prefixed; US ships the raw USITC
    # JSON as dataset_json instead)
    ctx["explorer_json"] = (f"{ctx['jur_lower']}_{res.year}_revision_{res.rev_num}.json"
                            if spec["source_format"] != "usitc" else "")
    # Derived duty rates (CA/EU/DO): per-chapter dir + index + treatments
    ctx["rates_dir"] = (f"{stem}.rates" if spec.get("duty_rates") else "")
    ctx["rates_index"] = (f"{stem}.rates.index.json" if spec.get("duty_rates") else "")
    ctx["treatments_json"] = (f"{ctx['jur_lower']}.treatments.json"
                              if spec.get("duty_rates") else "")
    ctx["env_snapshot"] = os.environ.get("HTS_ENV_SNAPSHOT_PATH",
                                         "/tmp/hts-env-snapshot.json")
    return ctx


# ─── Planning ────────────────────────────────────────────────────────

def plan_steps(spec: dict, from_step: str | None, only: str | None,
               until: str | None, dry_run: bool):
    steps = list(spec["steps"])
    if only:
        if only not in steps:
            sys.exit(f"ERROR: --only {only!r} is not in {spec['code']}'s steps {steps}")
        scheduled = [only]
    else:
        start = 0
        if from_step:
            if from_step.isdigit():
                idx = int(from_step) - 1
                if not (0 <= idx < len(steps)):
                    sys.exit(f"ERROR: --from-step {from_step} out of range 1-{len(steps)} "
                             f"for {spec['code']} ({steps})")
                from_step = steps[idx]
                print(f"[plan] --from-step {idx + 1} = {from_step!r} for {spec['code']}")
            if from_step not in steps:
                sys.exit(f"ERROR: --from-step {from_step!r} is not in {spec['code']}'s "
                         f"steps {steps}")
            start = steps.index(from_step)
        end = len(steps)
        if until:
            if until not in steps:
                sys.exit(f"ERROR: --until {until!r} is not in {spec['code']}'s steps {steps}")
            end = steps.index(until) + 1
        scheduled = steps[start:end]
    if dry_run:
        scheduled = [s for s in scheduled if not REGISTRY[s].skip_on_dry_run]
    return scheduled


def required_env(spec: dict, scheduled: list[str]) -> list[str]:
    need: list[str] = []
    for s in scheduled:
        for var in REGISTRY[s].requires_env:
            if var not in need:
                need.append(var)
    return need


def preflight_artifacts(spec: dict, scheduled: list[str], ctx: RunCtx) -> list[str]:
    """For every scheduled step, every consumed artifact whose producer is NOT
    scheduled must already exist on disk. Returns a list of error strings."""
    errors = []
    for s in scheduled:
        for key in step_consumes(spec, s):
            producer = producer_of(spec, key)
            if producer in scheduled:
                continue
            path = ctx.get(key)
            exists = Path(path).exists() if path else False   # rates_dir is a DIRECTORY
            if not exists:
                errors.append(
                    f"step {s!r} consumes {key} ({path or 'unset'}), but its "
                    f"producer {producer!r} is not scheduled and the file does "
                    f"not exist. Re-run from an earlier step.")
    return errors


# ─── Env file ────────────────────────────────────────────────────────

def load_env_file() -> None:
    env_file = HERE / ".env.hts_automation"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key.strip(), value)


# ─── Step implementations ────────────────────────────────────────────

def do_build(spec: dict, ctx: RunCtx, args) -> None:
    cmd = [sys.executable, str(HERE / "build_hts_corpus.py"),
           str(ctx["source_csv"]), spec["chapters_file"], ctx["stem"],
           "--jurisdiction", spec["code"], "--revision", ctx["revision"],
           "--max-depth", str(spec["max_depth"])]
    if spec["source_format"] != "usitc":
        cmd += ["--source-format", spec["source_format"]]
    if spec.get("lang", "en") != "en":
        cmd += ["--lang", spec["lang"]]
    run(cmd, REGISTRY["build"].exit_code)
    for key in ("corpus_jsonl", "codes_json"):
        if not ctx.artifact(key).is_file():
            sys.exit(f"ERROR: build did not produce {ctx[key]}")
    if ctx.get("explorer_json"):
        ecmd = [sys.executable, str(HERE / "build_explorer_dataset.py"),
                str(ctx["source_csv"]),
                "--source-format", spec["source_format"],
                "--jurisdiction", spec["code"],
                "--out", ctx["explorer_json"]]
        if spec.get("lang", "en") != "en":
            ecmd += ["--lang", spec["lang"]]
        run(ecmd, REGISTRY["build"].exit_code)
    duty = spec.get("duty_rates")
    if duty and not ctx.get(duty.get("source_key", "source_csv")):
        # Resuming without the acquire step: the staged workbook path is gone.
        print("  WARNING: duty-rates source not staged (resumed run?) — "
              "skipping build_duty_rates; re-run from acquire to refresh rates",
              file=sys.stderr)
        duty = None
    if duty:
        fmt = duty.get("source_format", spec["source_format"])
        dcmd = [sys.executable, str(HERE / "build_duty_rates.py"),
                str(ctx[duty.get("source_key", "source_csv")]),
                "--source-format", fmt,
                "--jurisdiction", spec["code"],
                "--revision", ctx["revision"]]
        if fmt == "taric":
            dcmd += ["--nomenclature", str(ctx["source_csv"]),
                     "--snapshot-date", str(ctx["effective_date"])]
            for key, flag in (("eu_geo_xlsx", "--geo-areas"),
                              ("eu_exclusions_xlsx", "--exclusions"),
                              ("eu_conditions_xlsx", "--conditions"),
                              ("eu_addcodes_xlsx", "--addcodes")):
                if ctx.get(key):
                    dcmd += [flag, str(ctx[key])]
        run(dcmd, REGISTRY["build"].exit_code)


def do_verify(spec: dict, ctx: RunCtx, args) -> None:
    gates = spec.get("verify") or {}
    registry = spec.get("registry")
    cmd = [sys.executable, str(HERE / "diff_revisions.py"),
           "--curr", ctx["codes_json"], "--curr-jsonl", ctx["corpus_jsonl"],
           "--jurisdiction", spec["code"], "--out", ctx["diff_json"]]
    if registry:
        cmd += ["--registry", registry]
    for gate, flag in (("max_removed_pct", "--max-removed-pct"),
                       ("max_added_pct", "--max-added-pct"),
                       ("max_leaf_to_internal_pct", "--max-leaf-to-internal-pct"),
                       ("max_redescribed_pct", "--max-redescribed-pct")):
        if gate in gates:
            cmd += [flag, str(gates[gate])]
    if getattr(args, "allow_large_diff", False):
        cmd += ["--allow-large-diff"]
    if os.environ.get("SAIL_GTX_REPO_PAT"):
        cmd += ["--fetch-prev"]
    run(cmd, REGISTRY["verify"].exit_code)


def do_publish(spec: dict, ctx: RunCtx, args) -> None:
    pub = spec.get("publish") or {}
    cmd = [sys.executable, str(HERE / "pinecone_sync.py"), "swap",
           "--jsonl", ctx["corpus_jsonl"], "--namespace", ctx["namespace"],
           "--keep", str(args.keep if args.keep is not None else pub.get("keep", 3))]
    if pub.get("golden_queries"):
        cmd += ["--golden-queries", pub["golden_queries"]]
    run(cmd, REGISTRY["publish"].exit_code)


def do_register(spec: dict, ctx: RunCtx, args) -> None:
    reg = spec.get("register") or {}
    cmd = [sys.executable, str(HERE / "supabase_insert_revision.py"),
           "--country", spec["code"],
           "--year", str(ctx["year"]),
           "--rev-num", str(ctx["number"]),
           "--effective-date", ctx["effective_date"],
           "--effective-date-label", ctx["effective_date_label"],
           "--tariff-schedule-name", spec["tariff_schedule_name"],
           "--ragie-partition-id", render(reg.get("ragie_partition_id_template",
                                                  "{jur_lower}_tariff_{year}"), ctx),
           "--pinecone-namespace", ctx["namespace"]]
    if reg.get("promote_country_pointer"):
        cmd += ["--promote-country-pointer"]
    run(cmd, REGISTRY["register"].exit_code)
    append_registry(spec, ctx)


def append_registry(spec: dict, ctx: RunCtx) -> None:
    """Record the published revision in the per-jurisdiction registry CSV.
    (config/revision_dates.csv is US-only and owned by the R scrape — never
    written here.)"""
    registry = spec.get("registry")
    if not registry:
        return
    import csv as _csv
    import datetime as _dt
    path = Path(registry)
    rows = []
    if path.exists():
        with path.open(newline="", encoding="utf-8") as fh:
            rows = list(_csv.DictReader(fh))
    fields = ["revision", "effective_date", "effective_date_label",
              "source_url", "source_sha256", "acquired_at", "notes"]
    new = {"revision": ctx["revision"], "effective_date": ctx["effective_date"],
           "effective_date_label": ctx["effective_date_label"],
           "source_url": ctx.get("source_url", ""),
           "source_sha256": ctx.get("source_sha256", ""),
           "acquired_at": _dt.datetime.now(_dt.timezone.utc)
                             .isoformat(timespec="seconds"),
           "notes": ""}
    replaced = False
    for i, r in enumerate(rows):
        if r.get("revision") == new["revision"]:
            # MERGE, never replace: a resumed run resolves offline and has no
            # source_url — overwriting a populated field with "" would destroy
            # provenance recorded by the original acquire.
            merged = dict(r)
            for k, v in new.items():
                if v:
                    merged[k] = v
            merged["notes"] = r.get("notes", "")
            rows[i] = merged
            replaced = True
    if not replaced:
        rows.append(new)
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = _csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    print(f"  registry updated -> {registry}")


def do_ship(spec: dict, ctx: RunCtx, args) -> None:
    ship = spec.get("ship") or {}
    cmd = [sys.executable, str(HERE / "sail_gtx_commit.py"),
           "--owner", ship.get("owner", "SAIL-Engineering"),
           "--repo", ship.get("repo", "sail-gtx-prerelease"),
           "--branch", os.environ.get("SAIL_GTX_PRODUCTION_BRANCH", "")]
    if ship.get("dest_path"):
        cmd += ["--source", str(ctx[ship.get("source", "dataset_json")]),
                "--dest-path", render(ship["dest_path"], ctx)]
    for extra in ship.get("also", []):
        src_path = ctx.get(extra.get("from", ""))
        if not src_path:
            sys.exit(f"ERROR: ship.also references unknown/empty artifact key "
                     f"{extra.get('from')!r} — check the jurisdiction spec")
        cmd += ["--also", f"{src_path}:{render(extra['to'], ctx)}"]
    cmd += ["--prune-keep", str(ship.get("prune_keep", 3))]
    if ship.get("tag_name"):
        cmd += ["--tag-name", render(ship["tag_name"], ctx)]
    cmd += ["--commit-message",
            render(ship.get("commit_message",
                            "chore: {jur} tariff {revision} artifacts"), ctx)]
    if args.dry_run:
        cmd += ["--dry-run"]
    run(cmd, REGISTRY["ship"].exit_code)


def do_envvars(spec: dict, ctx: RunCtx, args) -> None:
    run([sys.executable, str(HERE / "update_env_vars.py"), "set",
         "--year", str(ctx["year"]), "--rev-num", str(ctx["number"]),
         "--effective-date-label", ctx["effective_date_label"],
         "--snapshot-out", ctx["env_snapshot"]],
        REGISTRY["envvars"].exit_code)


def do_smoke(spec: dict, ctx: RunCtx, args) -> None:
    smoke = spec.get("smoke") or {}
    cmd = [sys.executable, str(HERE / "smoke_test.py"),
           "--year", str(ctx["year"]), "--rev-num", str(ctx["number"]),
           "--country", smoke.get("country", spec["code"])]
    if smoke.get("golden_queries"):
        cmd += ["--golden-queries", smoke["golden_queries"]]
    if not getattr(args, "run_classify", False):
        cmd += ["--skip-classify"]
    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        print("\nSmoke test FAILED.", file=sys.stderr)
        snapshot = Path(ctx["env_snapshot"])
        if "envvars" in spec["steps"] and snapshot.exists():
            print("Rolling back env vars from snapshot...", file=sys.stderr)
            subprocess.run([sys.executable, str(HERE / "update_env_vars.py"),
                            "revert", "--snapshot", str(snapshot)])
        sys.exit(REGISTRY["smoke"].exit_code)


STEP_IMPL = {"build": do_build, "verify": do_verify, "publish": do_publish,
             "register": do_register, "ship": do_ship, "envvars": do_envvars,
             "smoke": do_smoke}


# ─── Main ────────────────────────────────────────────────────────────

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--jurisdiction", "-j", required=True, help="US, CA, EU, DO, ...")
    p.add_argument("--revision", help="override, e.g. 2026_rev_8")
    p.add_argument("--dry-run", action="store_true",
                   help="build + report; skip every externally-writing step "
                        "(ship still runs with its own --dry-run)")
    p.add_argument("--from-step", help="step name, or 1-based index into this "
                                       "jurisdiction's step list")
    p.add_argument("--only", help="run exactly one step")
    p.add_argument("--until", help="stop after this step")
    p.add_argument("--plan-only", action="store_true",
                   help="print the plan (steps, env, artifacts) and exit")
    p.add_argument("--acquire-adapter", help="override the spec's adapter "
                                             "(e.g. manual when a scraper breaks)")
    p.add_argument("--source", help="manual adapter: path to the source file")
    p.add_argument("--effective-date", help="manual adapter: ISO effective date")
    p.add_argument("--keep", type=int, default=None,
                   help="namespaces to retain at publish (default: spec, usually 3)")
    p.add_argument("--skip-scrape", action="store_true",
                   help="usitc adapter: skip the USITC release-list scrape")
    p.add_argument("--run-classify", action="store_true",
                   help="smoke: also run the classify canary")
    p.add_argument("--allow-large-diff", action="store_true",
                   help="verify: accept a diff beyond the gates (known restructure)")
    args = p.parse_args()

    os.chdir(REPO_ROOT)
    spec = load_spec(spec_path_for(args.jurisdiction))

    adapter_name = args.acquire_adapter or spec["acquire"]["adapter"]
    adapter = get_adapter(adapter_name)

    scheduled = plan_steps(spec, args.from_step, args.only, args.until, args.dry_run)

    # System-binary preflight (mdbtools etc.) — before any network call.
    if "acquire" in scheduled and not args.acquire_adapter:
        for binary in spec["acquire"].get("system_requires", []):
            if not shutil.which(binary):
                sys.exit(f"ERROR: {binary!r} not found on PATH (needed by the "
                         f"{adapter_name} adapter).\n"
                         f"  Debian/Ubuntu: sudo apt-get install -y mdbtools\n"
                         f"  macOS:         brew install mdbtools\n"
                         f"Or export the table elsewhere and re-run with "
                         f"--acquire-adapter manual --source <csv>.")

    load_env_file()
    need = required_env(spec, scheduled)
    missing = [v for v in need if not os.environ.get(v)]

    # Resolve (read-only) always runs; acquire (network) only when scheduled
    # and never under --plan-only.
    log(f"resolve {spec['code']} revision ({adapter_name})")
    do_fetch = "acquire" in scheduled and not args.plan_only
    res = adapter.fetch(spec, args) if do_fetch else adapter.resolve(spec, args)
    ctx = build_ctx(spec, res)
    ctx["source_url"] = getattr(res, "source_url", "")
    ctx["source_sha256"] = getattr(res, "source_sha256", "")
    ctx.update(getattr(res, "extras", {}) or {})

    errors = preflight_artifacts(spec, scheduled, ctx)

    print(f"\n[plan] jurisdiction {spec['code']}  revision {ctx['revision']}  "
          f"namespace {ctx['namespace']}")
    for i, s in enumerate(spec["steps"], 1):
        mark = "RUN " if s in scheduled else "skip"
        print(f"[plan]   {i}. [{mark}] {s}")
    if need:
        print(f"[plan] env required: {', '.join(need)}")
    if args.plan_only:
        for e in errors:
            print(f"[plan] PREFLIGHT: {e}")
        if missing:
            print(f"[plan] env MISSING: {', '.join(missing)}")
        return 0

    if missing:
        sys.exit(f"ERROR: missing env vars for scheduled steps: {', '.join(missing)}\n"
                 f"       (set them in scripts/hts_automation/.env.hts_automation)")
    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 2

    for s in scheduled:
        if s == "acquire":
            continue  # already ran with resolve above
        log(f"step {s} ({spec['code']} {ctx['revision']})")
        STEP_IMPL[s](spec, ctx, args)

    log(f"DONE — {spec['code']} {ctx['revision']} "
        f"(effective {ctx['effective_date']}): {' -> '.join(scheduled)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
