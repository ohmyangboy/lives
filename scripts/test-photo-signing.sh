#!/bin/bash
# 用真实签名验证运行前检查；不调用 PhotoKit、不弹框、不更改系统授权。
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/lives-photo-signing.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT

cat > "$probe_dir/main.swift" <<'SWIFT'
import Foundation
import Darwin

let expected = CommandLine.arguments[1]
do {
    try PhotoAuthorization.validateSigningConfiguration()
    guard expected == "allowed" else { exit(1) }
    print("签名包含照片权限：运行前检查通过")
} catch let error as ServiceError {
    guard expected == "rejected", error.code == "PHOTO_PERMISSION_CONFIGURATION_ERROR" else { exit(1) }
    print("签名缺少照片权限：正确报告应用配置错误")
} catch {
    exit(1)
}
SWIFT

swiftc -module-cache-path "$probe_dir/module-cache" \
  "$project_root/native/LivePhotoService/Sources/LivePhotoService/Protocol.swift" \
  "$project_root/native/LivePhotoService/Sources/LivePhotoService/PhotoAuthorization.swift" \
  "$probe_dir/main.swift" -o "$probe_dir/missing-permission"
cp "$probe_dir/missing-permission" "$probe_dir/with-permission"
codesign --force --sign - --options runtime "$probe_dir/missing-permission"
codesign --force --sign - --options runtime \
  --entitlements "$project_root/src-tauri/Entitlements.plist" "$probe_dir/with-permission"

"$probe_dir/missing-permission" rejected
"$probe_dir/with-permission" allowed
if python3 "$project_root/scripts/verify-photo-permissions.py" "$probe_dir/missing-permission"; then
  echo "错误：打包检查没有拦截缺少照片权限的签名" >&2
  exit 1
fi
python3 "$project_root/scripts/verify-photo-permissions.py" "$probe_dir/with-permission"
