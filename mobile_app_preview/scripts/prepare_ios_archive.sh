#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if [ "${DM_CLEAN_WORKTREE:-0}" != "1" ]; then
  exec ./scripts/run_from_clean_workspace.sh ./scripts/prepare_ios_archive.sh "$@"
fi

API_BASE_URL="${API_BASE_URL:-https://api2.dansmagazin.net}"
GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID:-715936767290-0urophgn1ao2e9rsiibhg2lnao96n9af.apps.googleusercontent.com}"
GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com}"
SHA="$(git rev-parse --short HEAD)"

if [ ! -f ios/Runner/GoogleService-Info.plist ]; then
  echo "ERROR: ios/Runner/GoogleService-Info.plist bulunamadi." >&2
  echo "iOS archive hazirligi icin Firebase iOS config dosyasi gerekli." >&2
  exit 1
fi

./scripts/release_guard.sh
flutter clean
flutter pub get
cd ios
pod install
cd ..
flutter build ios --release --no-codesign \
  --dart-define=API_BASE_URL="$API_BASE_URL" \
  --dart-define=APP_BUILD_SHA="$SHA" \
  --dart-define=GOOGLE_SERVER_CLIENT_ID="$GOOGLE_SERVER_CLIENT_ID" \
  --dart-define=GOOGLE_IOS_CLIENT_ID="$GOOGLE_IOS_CLIENT_ID"

echo "iOS release build hazirlandi. Xcode ile archive/upload icin:"
echo "Calisma klasoru: $repo_root"
echo "open ios/Runner.xcworkspace"
