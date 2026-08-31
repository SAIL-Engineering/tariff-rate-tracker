#!/usr/bin/env python3
"""set_repo_secrets.py — push the automation secrets/vars this repo's nightly
workflow needs to GitHub Actions, reading values from .env.hts_automation.

Run this YOURSELF (it handles credentials, so the agent won't):

    python3 scripts/hts_automation/set_repo_secrets.py            # do it
    python3 scripts/hts_automation/set_repo_secrets.py --dry-run  # show plan

Requires: PyNaCl (`pip install pynacl`) for GitHub's libsodium sealed boxes,
and a PAT with admin access to SAIL-Engineering/tariff-rate-tracker — it uses
SAIL_GTX_REPO_PAT from .env.hts_automation, or pass --pat-env OTHER_VAR.
If the PAT lacks repo-admin scope, set them by hand instead:
Settings → Secrets and variables → Actions (list printed by --dry-run).
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = "SAIL-Engineering/tariff-rate-tracker"

SECRETS = ["PINECONE_API_KEY", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY",
           "RAILWAY_TOKEN", "RAILWAY_PROJECT_ID", "RAILWAY_SERVICE_ID",
           "RAILWAY_ENVIRONMENT_ID", "VERCEL_TOKEN", "VERCEL_PROJECT_ID",
           "VERCEL_TEAM_ID", "SAIL_GTX_REPO_PAT", "SAIL_GTX_API_AUTH_TOKEN"]
VARIABLES = ["SAIL_GTX_PRODUCTION_BRANCH", "SAIL_GTX_HEALTHCHECK_URL",
             "SAIL_GTX_API_BASE"]


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    path = HERE / ".env.hts_automation"
    if not path.exists():
        sys.exit(f"ERROR: {path} not found")
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip()
    return env


def api(pat: str, method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        f"https://api.github.com{path}", method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {pat}",
                 "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = resp.read().decode()
        return json.loads(data) if data else {}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--pat-env", default="SAIL_GTX_REPO_PAT")
    args = p.parse_args()

    env = load_env()
    print(f"Target: {REPO}\n")
    todo_s = [(n, env.get(n, "")) for n in SECRETS]
    todo_v = [(n, env.get(n, "")) for n in VARIABLES]
    for name, val in todo_s:
        print(f"  secret   {name:28s} {'✓ from .env' if val else '✗ MISSING in .env'}")
    for name, val in todo_v:
        print(f"  variable {name:28s} {val if val else '✗ MISSING in .env'}")
    if args.dry_run:
        return 0

    pat = env.get(args.pat_env) or os.environ.get(args.pat_env, "")
    if not pat:
        sys.exit(f"ERROR: no PAT in {args.pat_env}")
    try:
        from nacl import encoding, public  # type: ignore
    except ImportError:
        sys.exit("ERROR: PyNaCl required: pip install pynacl")

    key = api(pat, "GET", f"/repos/{REPO}/actions/secrets/public-key")
    pk = public.PublicKey(key["key"].encode(), encoding.Base64Encoder())
    box = public.SealedBox(pk)

    for name, val in todo_s:
        if not val:
            print(f"  SKIP secret {name} (no value)"); continue
        sealed = base64.b64encode(box.encrypt(val.encode())).decode()
        api(pat, "PUT", f"/repos/{REPO}/actions/secrets/{name}",
            {"encrypted_value": sealed, "key_id": key["key_id"]})
        print(f"  set secret {name}")
    for name, val in todo_v:
        if not val:
            print(f"  SKIP variable {name} (no value)"); continue
        try:
            api(pat, "POST", f"/repos/{REPO}/actions/variables",
                {"name": name, "value": val})
        except urllib.error.HTTPError as exc:
            if exc.code == 409:
                api(pat, "PATCH", f"/repos/{REPO}/actions/variables/{name}",
                    {"name": name, "value": val})
            else:
                raise
        print(f"  set variable {name}")
    print("\nDone. Trigger a dispatch with dry_run=true to verify:")
    print("  https://github.com/SAIL-Engineering/tariff-rate-tracker/actions/workflows/hts-revision-update.yml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
