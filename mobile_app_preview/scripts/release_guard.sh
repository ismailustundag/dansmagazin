#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

sha="$(git rev-parse --short HEAD)"

print_dirty_files() {
  git status --short
}

has_dirty_worktree() {
  ! git diff --quiet || ! git diff --cached --quiet
}

if has_dirty_worktree; then
  echo "RELEASE GUARD ERROR"
  echo "Commit SHA: $sha"
  echo "Calisma alani temiz degil. Bu durumda build, gorunen SHA ile birebir eslesmeyebilir."
  echo
  print_dirty_files
  echo
  echo "Cozum:"
  echo "1. Degisiklikleri commit et"
  echo "2. veya bilincli local build gerekiyorsa ALLOW_DIRTY_RELEASE=1 ile tekrar calistir"
  if [[ "${ALLOW_DIRTY_RELEASE:-0}" != "1" ]]; then
    exit 1
  fi
  echo "ALLOW_DIRTY_RELEASE=1 verildigi icin devam ediliyor."
fi

echo "Release guard OK: HEAD=$sha"
