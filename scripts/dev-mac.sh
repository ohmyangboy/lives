#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

mode="${1:-dev}"
if [[ $# -gt 0 ]]; then shift; fi

case "$mode" in
  dev)
    export LIVES_DEV_PHOTOS_HELPER_APP="$project_root/src-tauri/resources/LiveCollagePhotosHelper.app"
    exec npm run tauri -- dev "$@"
    ;;
  app)
    unset LIVES_DEV_PHOTOS_HELPER_APP
    npm run tauri -- build --debug --bundles app
    app_path="$project_root/src-tauri/target/debug/bundle/macos/Lives.app"
    python3 scripts/verify-photo-permissions.py "$app_path"
    open "$app_path"
    ;;
  *)
    echo "用法：bash scripts/dev-mac.sh [dev|app]" >&2
    exit 2
    ;;
esac
