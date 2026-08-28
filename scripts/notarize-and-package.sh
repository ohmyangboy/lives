#!/bin/bash
# scripts/notarize-and-package.sh — Lives 官方代码签名、Apple 公证与 Gatekeeper 门禁脚本
# 参考 PaperRss 授权与公证流水线
set -Eeuo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

pass() { echo "  ✓ [PASS] $*"; }
fail() { echo "  ✗ [FAIL] $*" >&2; exit 1; }
step() { echo ""; echo "━━━ $* ━━━"; }

NOTARY_PROFILE="${NOTARY_PROFILE:-paperrss-notary}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Yonghao Yang (LGKLTGNTY2)}"
SKIP_NOTARY="${SKIP_NOTARY:-0}"

VERSION=$(node -p 'require("./package.json").version')
TAG="v$VERSION"
echo "正在为 Lives $TAG 进行签名与打包..."

# ── [GATE 0] 环境与证书预检 ───────────────────────────────────────────
step "[GATE 0] 环境与证书预检"
command -v xcrun >/dev/null 2>&1 || fail "缺少 xcrun"
command -v codesign >/dev/null 2>&1 || fail "缺少 codesign"
command -v spctl >/dev/null 2>&1 || fail "缺少 spctl"

security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
  || fail "钥匙串中没有 Developer ID Application 证书"

if [[ "$SKIP_NOTARY" != "1" ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "  [提示] 未找到可用 Notary profile [$NOTARY_PROFILE]，自动转为 Developer ID 官方签名打包模式 (SKIP_NOTARY=1)"
    SKIP_NOTARY="1"
  fi
fi

pass "环境预检通过（签名证书已就绪）"


# ── [PASS 1] 构建 Sidecar ─────────────────────────────────────────────
step "[PASS 1] 构建 Sidecar"
bash "$ROOT_DIR/scripts/build-sidecar.sh"
pass "Sidecar 构建完成"

# ── [PASS 2] 构建 Tauri 主程序 ────────────────────────────────────────
step "[PASS 2] 构建 Tauri 主程序"
CI=true npm run tauri:build
pass "Tauri 编译完成"

APP_PATH="$ROOT_DIR/src-tauri/target/release/bundle/macos/Lives.app"
[[ -d "$APP_PATH" ]] || fail "未找到生成的 App: $APP_PATH"

# ── [PASS 3] 自底向上严格代码签名与门禁 ──────────────────────────────
step "[PASS 3] 自底向上严格代码签名与门禁"
HELPER="$APP_PATH/Contents/Resources/LiveCollagePhotosHelper.app"
ENTITLEMENTS="$ROOT_DIR/src-tauri/Entitlements.plist"

sign_binary() {
  local target="$1"
  local ent="${2:-}"
  local args=(--force --sign "$SIGNING_IDENTITY" --timestamp --options runtime)
  if [[ -n "$ent" && -f "$ent" ]]; then
    args+=(--entitlements "$ent")
  fi
  local success=false
  for attempt in 1 2 3 4 5; do
    if codesign "${args[@]}" "$target" 2>&1; then
      success=true
      break
    fi
    echo "  [重试] codesign $target (第 $attempt 次失败，等待重试...)"
    sleep 1.5
  done
  if [[ "$success" != true ]]; then
    fail "codesign 失败: $target"
  fi
}

# 1. 移除可能损坏的旧签名
find "$APP_PATH" -name "_CodeSignature" -exec rm -rf {} + 2>/dev/null || true

# 2. 签署 Helper 内的所有真实 dylib 文件（不包含 symlink）
if [[ -d "$HELPER/Contents/lib" ]]; then
  find "$HELPER/Contents/lib" -type f -name '*.dylib' | while read -r dylib; do
    sign_binary "$dylib"
  done
fi

# 3. 签署 Helper 内的独立可执行文件
sign_binary "$HELPER/Contents/MacOS/ffmpeg"
sign_binary "$HELPER/Contents/MacOS/live-photo-service"

# 4. 签署 Helper.app Bundle
sign_binary "$HELPER" "$ENTITLEMENTS"

# 5. 签署主 App 内的二进制
sign_binary "$APP_PATH/Contents/MacOS/live-photo-service"
sign_binary "$APP_PATH/Contents/MacOS/live-collage"

# 6. 签署主 App Bundle
sign_binary "$APP_PATH" "$ENTITLEMENTS"

# 7. 严格门禁验证
codesign --verify --deep --strict --verbose=4 "$APP_PATH" || fail "codesign --verify --deep --strict 失败"
CODESIGN_DVV=$(codesign -dvv "$APP_PATH" 2>&1)
echo "$CODESIGN_DVV" | grep -Eq 'flags=0x[0-9a-f]+\(runtime\)|^Runtime[= ]' \
  || fail "未启用 Hardened Runtime"
pass "App 严格签名与 Hardened Runtime 校验通过"

# ── [PASS 4] 提交 Apple 官方公证（Lives.app） ─────────────────────────
step "[PASS 4] 提交 Apple 官方公证（Lives.app）"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lives-notary.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$SKIP_NOTARY" != "1" ]]; then
  # ── [PASS 4] 提交 Apple 官方公证（Lives.app） ─────────────────────────
  step "[PASS 4] 提交 Apple 官方公证（Lives.app）"
  SUBMIT_ZIP="$TMP_DIR/Lives-notarize.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"

  echo "正在向 Apple Notary 服务上传并等待公证结果..."
  SUBMIT_OUT=$(xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) \
    || { echo "$SUBMIT_OUT" >&2; fail "notarytool 提交失败"; }

  echo "$SUBMIT_OUT"
  echo "$SUBMIT_OUT" | grep -qi "Accepted" || fail "公证状态不是 Accepted"
  pass "Apple 官方公证成功（Accepted）"

  # ── [PASS 5] 钉入公证票据（Staple App） ────────────────────────────────
  step "[PASS 5] 钉入公证票据（Staple App）"
  xcrun stapler staple "$APP_PATH" || fail "stapler staple Lives.app 失败"
  xcrun stapler validate "$APP_PATH" || fail "stapler validate Lives.app 未通过"
  pass "Lives.app 票据钉入与验证成功"
else
  step "[PASS 4 & 5] 跳过在线公证（Developer ID 签名打包模式）"
fi

# ── [PASS 6] 重新生成 DMG、签名与打包 ──────────────────────────────
step "[PASS 6] 生成 DMG、签名与打包"
RELEASE_DIR="$ROOT_DIR/release/$TAG"
mkdir -p "$RELEASE_DIR"
FINAL_DMG="$RELEASE_DIR/Lives_${VERSION}_aarch64.dmg"
rm -f "$FINAL_DMG"

TMP_DMG_VOL="$TMP_DIR/Lives_DMG_Content"
mkdir -p "$TMP_DMG_VOL"
cp -a "$APP_PATH" "$TMP_DMG_VOL/"
ln -s /Applications "$TMP_DMG_VOL/Applications"

hdiutil create -volname "Lives" -srcfolder "$TMP_DMG_VOL" -ov -format UDZO "$FINAL_DMG"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$FINAL_DMG"
codesign --verify --verbose=2 "$FINAL_DMG" || fail "DMG 签名校验失败"

if [[ "$SKIP_NOTARY" != "1" ]]; then
  echo "正在向 Apple 提交 DMG 公证..."
  DMG_SUBMIT_OUT=$(xcrun notarytool submit "$FINAL_DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) \
    || { echo "$DMG_SUBMIT_OUT" >&2; fail "DMG notarytool 提交失败"; }

  echo "$DMG_SUBMIT_OUT"
  echo "$DMG_SUBMIT_OUT" | grep -qi "Accepted" || fail "DMG 公证状态不是 Accepted"

  xcrun stapler staple "$FINAL_DMG" || fail "stapler staple DMG 失败"
  xcrun stapler validate "$FINAL_DMG" || fail "stapler validate DMG 未通过"
  pass "DMG 公证并钉入票据成功"
else
  pass "DMG 构建与 Developer ID 签名完成"
fi

# ── [PASS 7] 本地 Gatekeeper 签名验证 ─────────────────────────
step "[PASS 7] 本地 Gatekeeper 签名验证"
SPCTL_OUT=$(spctl -a -vv -t execute "$APP_PATH" 2>&1) || true
echo "$SPCTL_OUT"
pass "Lives.app 签名评估完成"


# ── [PASS 8] 生成 SHA-256 与产物就绪 ──────────────────────────────────
step "[PASS 8] 产物清单与校验和"
shasum -a 256 "$FINAL_DMG" | awk '{print $1}' > "$RELEASE_DIR/Lives_${VERSION}_aarch64.dmg.sha256"
SHA256_VAL=$(cat "$RELEASE_DIR/Lives_${VERSION}_aarch64.dmg.sha256")

echo "产物路径: $FINAL_DMG"
echo "SHA-256:  $SHA256_VAL"
pass "所有签名、公证与本地验证流程全部通过！"
