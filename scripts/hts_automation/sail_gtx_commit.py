#!/usr/bin/env python3
"""
sail_gtx_commit.py — copy the new HTS JSON dataset into the sail-gtx-prerelease
repo and push to the production branch.

Idempotent: if the destination file already exists with identical bytes,
the script exits 0 without committing. Otherwise it commits with a generated
message and pushes to the production branch specified by `--branch`.

Authentication uses HTTPS basic-auth with the PAT — we clone using the URL
form `https://x-access-token:<PAT>@github.com/<owner>/<repo>.git` so no
git config or ~/.netrc setup is required on the runner.

Environment:
  SAIL_GTX_REPO_PAT     Fine-grained PAT with contents:write on sail-gtx-prerelease
  GIT_USER_NAME         Optional, defaults to 'sail-gtx-bot'
  GIT_USER_EMAIL        Optional, defaults to 'sail-gtx-bot@users.noreply.github.com'

Usage:
  python sail_gtx_commit.py \
      --owner SAIL-Engineering --repo sail-gtx-prerelease \
      --branch illegal-transshipment \
      --source data/hts_archives/hts_2026_revision_8.json \
      --dest-path server/data/hts/hts_2026_revision_8.json \
      --dest-path public/data/hts-explorer/hts_2026_revision_8.json \
      --tag-name hts-2026-rev8 \
      --commit-message "chore: HTS 2026 Rev 8 dataset (effective 2026-05-22)"

Pass --dest-path more than once to write the same source to several locations in
a single commit (the server reads server/data/hts/; the frontend HTS Explorer
fetches public/data/hts-explorer/). The Vite htsManifestPlugin regenerates
public/data/hts-explorer/manifest.json from these files at build time.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile


def _env(name: str, required: bool = True, default: str = "") -> str:
    v = os.environ.get(name, default).strip()
    if not v and required:
        sys.exit(f"ERROR: env var {name} is required")
    return v


# Secret strings (e.g. the PAT, which is embedded in the clone URL) to scrub from
# anything we echo — otherwise a live token lands in terminal scrollback / CI logs.
_SECRETS: list[str] = []


def _redact(text: str) -> str:
    for s in _SECRETS:
        if s:
            text = text.replace(s, "***")
    return text


def _run(cmd: list[str], cwd: str | None = None) -> str:
    print(f"$ {_redact(' '.join(cmd))}", flush=True)
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.stdout:
        print(_redact(r.stdout), end="", flush=True)
    if r.returncode != 0:
        sys.stderr.write(_redact(r.stderr))
        sys.exit(f"ERROR: command failed (rc={r.returncode})")
    return r.stdout


def _sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--owner", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--branch", required=True,
                   help="Production branch to push to (e.g. illegal-transshipment)")
    p.add_argument("--source", required=True, help="Local path to the JSON file")
    p.add_argument("--dest-path", required=True, action="append", dest="dest_paths",
                   metavar="PATH",
                   help="Path inside the target repo (repeatable to write the same "
                        "source to several locations in ONE commit, e.g. "
                        "server/data/hts/... AND public/data/hts-explorer/...).")
    p.add_argument("--commit-message", required=True)
    p.add_argument("--tag-name", default=None,
                   help="Optional lightweight tag, e.g. hts-2026-rev8")
    p.add_argument("--dry-run", action="store_true",
                   help="Clone + diff + write locally, but do not push")
    args = p.parse_args()

    if not os.path.isfile(args.source):
        sys.exit(f"ERROR: source file not found: {args.source}")

    token = _env("SAIL_GTX_REPO_PAT")
    _SECRETS.append(token)  # scrub the PAT from every echoed command / git output
    user_name = _env("GIT_USER_NAME", required=False, default="sail-gtx-bot") or "sail-gtx-bot"
    user_email = _env("GIT_USER_EMAIL", required=False,
                      default="sail-gtx-bot@users.noreply.github.com") \
        or "sail-gtx-bot@users.noreply.github.com"

    remote = f"https://x-access-token:{token}@github.com/{args.owner}/{args.repo}.git"

    workdir = tempfile.mkdtemp(prefix="sail-gtx-clone-")
    try:
        _run(["git", "clone", "--depth", "1", "--branch", args.branch, remote, workdir])

        _run(["git", "config", "user.name", user_name], cwd=workdir)
        _run(["git", "config", "user.email", user_email], cwd=workdir)

        src_sha = _sha256_of_file(args.source)
        changed: list[str] = []
        for dest_path in args.dest_paths:
            dest_abs = os.path.join(workdir, dest_path)
            os.makedirs(os.path.dirname(dest_abs), exist_ok=True)
            if os.path.isfile(dest_abs) and _sha256_of_file(dest_abs) == src_sha:
                print(f"no-op: {dest_path} already matches source (sha256={src_sha})")
                continue
            shutil.copyfile(args.source, dest_abs)
            _run(["git", "add", dest_path], cwd=workdir)
            changed.append(dest_path)

        if not changed:
            print("no-op: all destinations already match source; nothing to commit")
            return

        _run(["git", "commit", "-m", args.commit_message], cwd=workdir)

        if args.tag_name:
            _run(["git", "tag", args.tag_name], cwd=workdir)

        if args.dry_run:
            print("[dry-run] not pushing")
            return

        _run(["git", "push", "origin", f"HEAD:{args.branch}"], cwd=workdir)
        if args.tag_name:
            # `|| true`-style behaviour: tag push should not blow up the run
            # if the tag already exists on remote (idempotent re-runs).
            try:
                _run(["git", "push", "origin", args.tag_name], cwd=workdir)
            except SystemExit:
                print(f"warning: failed to push tag {args.tag_name} (may already exist)")
        print("push complete")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
