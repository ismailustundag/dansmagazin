#!/usr/bin/env bash
set -euo pipefail

msg="${1:-chore: update}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

git add -A
git commit -m "$msg"
git push origin main
git rev-parse --short HEAD
