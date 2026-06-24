#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if [ "${DM_CLEAN_WORKTREE:-0}" != "1" ]; then
  exec ./scripts/run_from_clean_workspace.sh ./scripts/build_android_appbundle.sh "$@"
fi

API_BASE_URL="${API_BASE_URL:-https://api2.dansmagazin.net}"
GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID:-715936767290-0urophgn1ao2e9rsiibhg2lnao96n9af.apps.googleusercontent.com}"
GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com}"
SHA="$(git rev-parse --short HEAD)"
OUT="$HOME/Desktop/dansmagazin-release-${SHA}.aab"

if [ ! -f android/app/google-services.json ]; then
  echo "ERROR: android/app/google-services.json bulunamadi." >&2
  echo "AAB build'i icin Firebase Android config dosyasi gerekli." >&2
  exit 1
fi

./scripts/release_guard.sh
flutter clean
flutter pub get
flutter build appbundle --release \
  --dart-define=API_BASE_URL="$API_BASE_URL" \
  --dart-define=APP_BUILD_SHA="$SHA" \
  --dart-define=GOOGLE_SERVER_CLIENT_ID="$GOOGLE_SERVER_CLIENT_ID" \
  --dart-define=GOOGLE_IOS_CLIENT_ID="$GOOGLE_IOS_CLIENT_ID"

cp build/app/outputs/bundle/release/app-release.aab "$OUT"
ls -lh "$OUT"
