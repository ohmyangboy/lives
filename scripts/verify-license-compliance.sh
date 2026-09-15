#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "[license] FAIL: $*" >&2; exit 1; }
require_file() { [[ -f "$1" ]] || fail "缺少文件：$1"; }
[[ $# -le 1 ]] || fail "用法：$0 [Lives.app]"
app_path="${1:-}"
for file in LICENSE LICENSING.md USER_TERMS.md SOURCE_CODE.md THIRD_PARTY_NOTICES.md TRADEMARKS.md vendor/ffmpeg/licenses/COPYING.LGPLv2.1 vendor/ffmpeg/BUILD-CONFIGURATION.txt; do
  require_file "$project_root/$file"
done
grep -q 'GNU GENERAL PUBLIC LICENSE' "$project_root/LICENSE" || fail "根 LICENSE 不是 GNU GPL v3 全文"
grep -q '第三方' "$project_root/USER_TERMS.md" || fail "终端条款缺少第三方权利例外"
python3 "$project_root/scripts/core_dependency.py" >/dev/null
if [[ -n "$app_path" ]]; then
  resources="$app_path/Contents/Resources"
  main_info_plist="$app_path/Contents/Info.plist"
  helper_info_plist="$resources/LiveCollagePhotosHelper.app/Contents/Info.plist"
  require_file "$main_info_plist"
  require_file "$helper_info_plist"
  require_file "$resources/Legal/LICENSE.txt"
  require_file "$resources/Legal/LICENSING.md"
  require_file "$resources/Legal/THIRD_PARTY_NOTICES.md"
  require_file "$resources/Legal/SOURCE_CODE.md"
  require_file "$resources/Legal/TRADEMARKS.md"
  require_file "$resources/LiveCollagePhotosHelper.app/Contents/Resources/FFmpeg/COPYING.LGPLv2.1"
  require_file "$resources/LiveCollagePhotosHelper.app/Contents/Resources/FFmpeg/BUILD-CONFIGURATION.txt"

  cmp -s "$project_root/LICENSE" "$resources/Legal/LICENSE.txt" || fail "App 内许可文本与仓库 LICENSE 不匹配"
  require_file "$resources/Legal/USER_TERMS.md"
  command -v node >/dev/null 2>&1 || fail "缺少 node，无法读取发布版本"
  command -v plutil >/dev/null 2>&1 || fail "缺少 plutil，无法校验 App 版本"
  expected_app_version=$(node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); if (!p.version) process.exit(1); process.stdout.write(p.version)' "$project_root/package.json") \
    || fail "无法从 package.json 读取发布版本"
  main_short_version=$(plutil -extract CFBundleShortVersionString raw -o - "$main_info_plist") \
    || fail "无法读取主 App CFBundleShortVersionString"
  main_bundle_version=$(plutil -extract CFBundleVersion raw -o - "$main_info_plist") \
    || fail "无法读取主 App CFBundleVersion"
  helper_short_version=$(plutil -extract CFBundleShortVersionString raw -o - "$helper_info_plist") \
    || fail "无法读取 Helper CFBundleShortVersionString"
  helper_bundle_version=$(plutil -extract CFBundleVersion raw -o - "$helper_info_plist") \
    || fail "无法读取 Helper CFBundleVersion"
  for bundled_version_record in \
    "主 App CFBundleShortVersionString=$main_short_version" \
    "主 App CFBundleVersion=$main_bundle_version" \
    "Helper CFBundleShortVersionString=$helper_short_version" \
    "Helper CFBundleVersion=$helper_bundle_version"; do
    bundled_version=${bundled_version_record#*=}
    [[ "$bundled_version" == "$expected_app_version" ]] \
      || fail "App 内版本不一致：package.json=$expected_app_version，但 $bundled_version_record"
  done
fi


echo "[license] PASS"
