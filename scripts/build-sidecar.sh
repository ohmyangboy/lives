#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
package_path="$project_root/native/LivePhotoService"
output_dir="$project_root/src-tauri/binaries"
helper_app="$project_root/src-tauri/resources/LiveCollagePhotosHelper.app"
helper_contents="$helper_app/Contents"
helper_macos="$helper_contents/MacOS"
helper_resources="$helper_contents/Resources"
helper_lib="$helper_contents/lib"
ffmpeg_root="$project_root/vendor/ffmpeg/macos-arm64"
ffmpeg_notices="$helper_resources/FFmpeg"
target_triple="$(uname -m)-apple-darwin"

if [[ "$target_triple" == "arm64-apple-darwin" ]]; then
  target_triple="aarch64-apple-darwin"
fi

if [[ ! -x "$ffmpeg_root/bin/ffmpeg" ]]; then
  echo "Bundled FFmpeg runtime is missing. Run scripts/build-ffmpeg-runtime.sh first." >&2
  exit 1
fi

env \
  CLANG_MODULE_CACHE_PATH=/private/tmp/livecollage-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/livecollage-swiftpm-cache \
  swift build --disable-sandbox --package-path "$package_path" -c release
mkdir -p "$output_dir"
cp "$package_path/.build/release/live-photo-service" "$output_dir/live-photo-service-$target_triple"
chmod +x "$output_dir/live-photo-service-$target_triple"
mkdir -p "$helper_macos" "$helper_resources" "$helper_lib" "$ffmpeg_notices"
find "$helper_lib" -mindepth 1 -delete
cp "$package_path/.build/release/live-photo-service" "$helper_macos/live-photo-service"
cp "$ffmpeg_root/bin/ffmpeg" "$helper_macos/ffmpeg"
cp -a "$ffmpeg_root/lib/." "$helper_lib/"
cp "$package_path/Sources/LivePhotoService/Helper-Info.plist" "$helper_contents/Info.plist"
cp "$project_root/src-tauri/icons/icon.icns" "$helper_resources/icon.icns"
cp "$project_root/vendor/ffmpeg/licenses/COPYING.LGPLv2.1" "$ffmpeg_notices/COPYING.LGPLv2.1"
cp "$project_root/vendor/ffmpeg/BUILD-CONFIGURATION.txt" "$ffmpeg_notices/BUILD-CONFIGURATION.txt"
chmod +x "$helper_macos/live-photo-service" "$helper_macos/ffmpeg"
find "$helper_lib" -type f -name '*.dylib' -exec codesign --force --sign - --timestamp=none {} \;
codesign --force --sign - --timestamp=none "$helper_macos/ffmpeg"
codesign --force --sign - --timestamp=none \
  --entitlements "$project_root/src-tauri/Entitlements.plist" \
  "$helper_app"
