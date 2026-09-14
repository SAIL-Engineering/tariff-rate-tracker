#!/usr/bin/env bash
# Point git at the tracked hooks in scripts/git-hooks (one-time, per clone).
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath scripts/git-hooks
chmod +x scripts/git-hooks/* 2>/dev/null || true
echo "Installed: core.hooksPath = scripts/git-hooks"
echo "The pre-commit hook now auto-regenerates frontend bundles when a YAML source is staged."
