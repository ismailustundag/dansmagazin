#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if [ "${DM_CLEAN_WORKTREE:-0}" != "1" ]; then
  exec ./scripts/run_from_clean_workspace.sh ./scripts/build_android_ota_release.sh "$@"
fi

SHOREBIRD_BIN="${SHOREBIRD_BIN:-$HOME/.shorebird/bin/shorebird}"
API_BASE_URL="${API_BASE_URL:-https://api2.dansmagazin.net}"
GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID:-715936767290-0urophgn1ao2e9rsiibhg2lnao96n9af.apps.googleusercontent.com}"
GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com}"
OTA_BUILD_SHA="${OTA_BUILD_SHA:-ota-baseline}"
SHA="$(git rev-parse --short HEAD)"
OUT="$HOME/Desktop/dansmagazin-ota-release-${SHA}.aab"

test -x "$SHOREBIRD_BIN" || { echo "ERROR: Shorebird CLI bulunamadi: $SHOREBIRD_BIN" >&2; exit 1; }
test -f shorebird.yaml || { echo "ERROR: shorebird.yaml bulunamadi." >&2; exit 1; }
test -f android/app/google-services.json || { echo "ERROR: Firebase Android config bulunamadi." >&2; exit 1; }

./scripts/release_guard.sh
flutter pub get
"$SHOREBIRD_BIN" release android --artifact aab \
  -DAPI_BASE_URL="$API_BASE_URL" \
  -DAPP_BUILD_SHA="$OTA_BUILD_SHA" \
  -DGOOGLE_SERVER_CLIENT_ID="$GOOGLE_SERVER_CLIENT_ID" \
  -DGOOGLE_IOS_CLIENT_ID="$GOOGLE_IOS_CLIENT_ID"

cp build/app/outputs/bundle/release/app-release.aab "$OUT"
ls -lh "$OUT"
