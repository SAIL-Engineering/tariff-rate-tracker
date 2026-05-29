#!/usr/bin/env python3
"""
update_env_vars.py — set VITE_HTS_REVISION_* on Railway + Vercel.

Two subcommands:
  set      Update env vars to new values. Prints the prior values as JSON to
           stdout so the workflow can capture them for rollback.
  revert   Restore env vars from a JSON file produced by an earlier `set`.

The variable names are the three the boot-time assertion + UI fallback read:
  VITE_HTS_REVISION_YEAR
  VITE_HTS_REVISION_NUMBER
  VITE_HTS_REVISION_EFFECTIVE_DATE

Environment (set subcommand):
  RAILWAY_TOKEN                Railway API token (Project or Team)
  RAILWAY_PROJECT_ID           Railway project UUID
  RAILWAY_SERVICE_ID           Railway service UUID
  RAILWAY_ENVIRONMENT_ID       Railway environment UUID (production)
  VERCEL_TOKEN                 Vercel personal/team token
  VERCEL_PROJECT_ID            Vercel project id (prj_...)
  VERCEL_TEAM_ID               Optional; only required if the project is on a team
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

import requests


HTS_VAR_NAMES = (
    "VITE_HTS_REVISION_YEAR",
    "VITE_HTS_REVISION_NUMBER",
    "VITE_HTS_REVISION_EFFECTIVE_DATE",
)

RAILWAY_API = "https://backboard.railway.com/graphql/v2"


def _env(name: str, required: bool = True) -> str:
    v = os.environ.get(name, "").strip()
    if not v and required:
        sys.exit(f"ERROR: env var {name} is required")
    return v


# ────────────────────────────────────────────────────────────────────
# Railway
# ────────────────────────────────────────────────────────────────────

def _railway_request(query: str, variables: dict[str, Any]) -> dict[str, Any]:
    token = _env("RAILWAY_TOKEN")
    r = requests.post(
        RAILWAY_API,
        headers={"authorization": f"Bearer {token}",
                 "content-type": "application/json"},
        data=json.dumps({"query": query, "variables": variables}),
        timeout=30,
    )
    r.raise_for_status()
    body = r.json()
    if body.get("errors"):
        sys.exit(f"ERROR: Railway GraphQL: {json.dumps(body['errors'])}")
    return body["data"]


def railway_get_vars() -> dict[str, str]:
    """Return the current variable map for the configured project/service/env."""
    query = """
    query Variables($projectId: String!, $environmentId: String!, $serviceId: String!) {
      variables(projectId: $projectId, environmentId: $environmentId, serviceId: $serviceId)
    }
    """
    data = _railway_request(query, {
        "projectId": _env("RAILWAY_PROJECT_ID"),
        "environmentId": _env("RAILWAY_ENVIRONMENT_ID"),
        "serviceId": _env("RAILWAY_SERVICE_ID"),
    })
    return data.get("variables") or {}


def railway_set_var(name: str, value: str) -> None:
    """Upsert a single variable. Triggers Railway's normal deploy pipeline."""
    mutation = """
    mutation Upsert($input: VariableUpsertInput!) {
      variableUpsert(input: $input)
    }
    """
    _railway_request(mutation, {
        "input": {
            "projectId": _env("RAILWAY_PROJECT_ID"),
            "environmentId": _env("RAILWAY_ENVIRONMENT_ID"),
            "serviceId": _env("RAILWAY_SERVICE_ID"),
            "name": name,
            "value": value,
        }
    })


# ────────────────────────────────────────────────────────────────────
# Vercel
# ────────────────────────────────────────────────────────────────────

def _vercel_headers() -> dict[str, str]:
    return {"authorization": f"Bearer {_env('VERCEL_TOKEN')}",
            "content-type": "application/json"}


def _vercel_team_param() -> dict[str, str]:
    team = _env("VERCEL_TEAM_ID", required=False)
    return {"teamId": team} if team else {}


def vercel_list_vars() -> list[dict[str, Any]]:
    project = _env("VERCEL_PROJECT_ID")
    r = requests.get(
        f"https://api.vercel.com/v9/projects/{project}/env",
        headers=_vercel_headers(),
        params=_vercel_team_param(),
        timeout=30,
    )
    r.raise_for_status()
    return r.json().get("envs", [])


def vercel_upsert_var(name: str, value: str, targets=("production",)) -> None:
    """Vercel env vars are immutable — to change, you delete + re-create."""
    project = _env("VERCEL_PROJECT_ID")
    existing = [e for e in vercel_list_vars() if e["key"] == name]
    # Remove only the rows targeting at least one of our targets, so we don't
    # disturb preview/development entries that should keep their own values.
    target_set = set(targets)
    for e in existing:
        if set(e.get("target", [])) & target_set:
            r = requests.delete(
                f"https://api.vercel.com/v9/projects/{project}/env/{e['id']}",
                headers=_vercel_headers(),
                params=_vercel_team_param(),
                timeout=30,
            )
            r.raise_for_status()
    body = {"key": name, "value": value, "type": "encrypted",
            "target": list(targets)}
    r = requests.post(
        f"https://api.vercel.com/v10/projects/{project}/env",
        headers=_vercel_headers(),
        params={**_vercel_team_param(), "upsert": "true"},
        data=json.dumps(body),
        timeout=30,
    )
    if r.status_code not in (200, 201):
        sys.exit(f"ERROR: Vercel env upsert failed ({r.status_code}): {r.text}")


def vercel_get_value(name: str, target: str = "production") -> str | None:
    for e in vercel_list_vars():
        if e["key"] == name and target in e.get("target", []):
            # Encrypted vars don't return a value via /v9/env — but the API
            # echoes plaintext on creation. For rollback we accept that
            # Railway snapshot is the authoritative prior-value source; we
            # mirror it onto Vercel.
            return e.get("value")
    return None


# ────────────────────────────────────────────────────────────────────
# Subcommands
# ────────────────────────────────────────────────────────────────────

def cmd_set(args: argparse.Namespace) -> None:
    new_values = {
        "VITE_HTS_REVISION_YEAR": str(args.year),
        "VITE_HTS_REVISION_NUMBER": str(args.rev_num),
        "VITE_HTS_REVISION_EFFECTIVE_DATE": args.effective_date_label,
    }

    prior_railway = railway_get_vars()
    snapshot = {name: prior_railway.get(name) for name in HTS_VAR_NAMES}

    for name, value in new_values.items():
        print(f"[railway] {name} → {value}", flush=True)
        railway_set_var(name, value)
        print(f"[vercel]  {name} → {value}", flush=True)
        vercel_upsert_var(name, value, targets=("production",))

    if args.snapshot_out:
        with open(args.snapshot_out, "w") as fh:
            json.dump({"railway_prior": snapshot, "new": new_values}, fh, indent=2)
        print(f"snapshot written to {args.snapshot_out}", flush=True)
    else:
        print(json.dumps({"railway_prior": snapshot, "new": new_values}))


def cmd_revert(args: argparse.Namespace) -> None:
    with open(args.snapshot, "r") as fh:
        snap = json.load(fh)
    prior = snap.get("railway_prior", {})
    for name in HTS_VAR_NAMES:
        value = prior.get(name)
        if value is None:
            print(f"[skip] {name}: no prior value captured", flush=True)
            continue
        print(f"[railway] revert {name} → {value}", flush=True)
        railway_set_var(name, value)
        print(f"[vercel]  revert {name} → {value}", flush=True)
        vercel_upsert_var(name, value, targets=("production",))


def main() -> None:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("set")
    sp.add_argument("--year", required=True)
    sp.add_argument("--rev-num", required=True)
    sp.add_argument("--effective-date-label", required=True,
                    help='Human-readable date, e.g. "May 22, 2026"')
    sp.add_argument("--snapshot-out",
                    help="Write prior values to this JSON path for rollback")
    sp.set_defaults(func=cmd_set)

    sp = sub.add_parser("revert")
    sp.add_argument("--snapshot", required=True)
    sp.set_defaults(func=cmd_revert)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
