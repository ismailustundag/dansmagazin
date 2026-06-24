#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
git_root="$(git -C "$project_root" rev-parse --show-toplevel)"
repo_name="$(basename "$git_root")"
builds_root="${RELEASE_WORKTREE_ROOT:-$HOME/${repo_name}_release_builds}"
release_ref="${RELEASE_REF:-origin/main}"
timestamp="$(date +%Y%m%d_%H%M%S)"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <command> [args...]" >&2
  exit 1
fi

command_path="$1"
shift

if git -C "$git_root" remote get-url origin >/dev/null 2>&1; then
  if ! git -C "$git_root" fetch origin; then
    echo "UYARI: origin fetch basarisiz oldu. Mevcut local refs ile devam ediliyor." >&2
  fi
fi

if ! git -C "$git_root" rev-parse --verify --quiet "${release_ref}^{commit}" >/dev/null; then
  release_ref="HEAD"
fi

sha="$(git -C "$git_root" rev-parse --short "$release_ref")"
worktree_root="${builds_root}/${sha}_${timestamp}"
clean_project_root="${worktree_root}/mobile_app_preview"

copy_if_present() {
  local source_path="$1"
  local target_path="$2"

  if [ -f "$source_path" ]; then
    mkdir -p "$(dirname "$target_path")"
    cp "$source_path" "$target_path"
  fi
}

copy_android_signing_files() {
  local source_key_properties="$project_root/android/key.properties"
  local target_key_properties="$clean_project_root/android/key.properties"
  local store_file=""
  local candidate=""
  local target_keystore=""

  if [ ! -f "$source_key_properties" ]; then
    return
  fi

  mkdir -p "$(dirname "$target_key_properties")"
  cp "$source_key_properties" "$target_key_properties"

  store_file="$(sed -n 's/^storeFile=//p' "$source_key_properties" | head -n 1 | tr -d '\r')"
  if [ -z "$store_file" ]; then
    return
  fi

  case "$store_file" in
    /*)
      if [ ! -f "$store_file" ]; then
        echo "UYARI: key.properties icindeki absolute storeFile bulunamadi: $store_file" >&2
      fi
      ;;
    *)
      for candidate in \
        "$project_root/android/app/$store_file" \
        "$project_root/android/$store_file" \
        "$project_root/$store_file"
      do
        if [ -f "$candidate" ]; then
          target_keystore="$clean_project_root/android/app/$store_file"
          mkdir -p "$(dirname "$target_keystore")"
          cp "$candidate" "$target_keystore"
          return
        fi
      done

      echo "UYARI: key.properties icindeki storeFile kopyalanamadi: $store_file" >&2
      ;;
  esac
}

mkdir -p "$builds_root"
git -C "$git_root" worktree add --detach "$worktree_root" "$release_ref" >/dev/null

copy_if_present \
  "$project_root/android/app/google-services.json" \
  "$clean_project_root/android/app/google-services.json"
copy_if_present \
  "$project_root/ios/Runner/GoogleService-Info.plist" \
  "$clean_project_root/ios/Runner/GoogleService-Info.plist"
copy_android_signing_files

echo "Temiz release workspace hazirlandi: $clean_project_root"
echo "Build ref'i: $release_ref"
echo "Build commit'i: $sha"

cd "$clean_project_root"
exec env DM_CLEAN_WORKTREE=1 "$command_path" "$@"
