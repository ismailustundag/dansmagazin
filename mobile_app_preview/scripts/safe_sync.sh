#!/usr/bin/env bash
set -euo pipefail

branch="${1:-main}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

stamp="autosync_$(date +%Y%m%d_%H%M%S)"
if [ -n "$(git status --porcelain)" ]; then
  git stash push -u -m "$stamp" >/dev/null
  stashed=1
else
  stashed=0
fi

git fetch origin
git pull --rebase origin "$branch"

if [ "$stashed" = "1" ]; then
  git stash pop || true
fi

git rev-parse --short HEAD
git status --short
