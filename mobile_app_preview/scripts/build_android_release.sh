#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

API_BASE_URL="${API_BASE_URL:-https://api2.dansmagazin.net}"
GOOGLE_SERVER_CLIENT_ID="${GOOGLE_SERVER_CLIENT_ID:-715936767290-0urophgn1ao2e9rsiibhg2lnao96n9af.apps.googleusercontent.com}"
GOOGLE_IOS_CLIENT_ID="${GOOGLE_IOS_CLIENT_ID:-715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com}"
SHA="$(git rev-parse --short HEAD)"
OUT="$HOME/Desktop/dansmagazin-release-${SHA}.apk"

flutter clean
flutter pub get
flutter build apk --release \
  --dart-define=API_BASE_URL="$API_BASE_URL" \
  --dart-define=APP_BUILD_SHA="$SHA" \
  --dart-define=GOOGLE_SERVER_CLIENT_ID="$GOOGLE_SERVER_CLIENT_ID" \
  --dart-define=GOOGLE_IOS_CLIENT_ID="$GOOGLE_IOS_CLIENT_ID"

cp build/app/outputs/flutter-apk/app-release.apk "$OUT"
ls -lh "$OUT"
