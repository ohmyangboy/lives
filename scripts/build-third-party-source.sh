#!/usr/bin/env bash
# 本脚本可随对应第三方源码资料再分发。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version=$(node -p "require('$root/package.json').version")
out="$root/release/v$version"
work=$(mktemp -d "${TMPDIR:-/tmp}/lives-third-party.XXXXXX")
trap 'rm -rf "$work"' EXIT
bundle="$work/third-party"
mkdir -p "$bundle/rust" "$bundle/ffmpeg" "$out"
cargo vendor --locked --versioned-dirs --manifest-path "$root/src-tauri/Cargo.toml" "$bundle/rust/vendor" > "$work/cargo-config.toml"
# 只收集 registry 第三方依赖；不复制仓库源码，也不把 registry 地址或凭据带入归档。
python3 - "$root/src-tauri/Cargo.lock" "$bundle/rust/vendor" <<'PY'
import json,sys,tomllib
from pathlib import Path
lock=tomllib.loads(Path(sys.argv[1]).read_text())
expected={f"{p['name']}-{p['version']}":p['checksum'] for p in lock['package'] if p.get('source','').startswith('registry+')}
if any(p.get('source','').startswith('git+') for p in lock['package']):
    raise SystemExit('新增 git 第三方依赖须先审查源码分发方式')
actual={p.name for p in Path(sys.argv[2]).iterdir()}
if actual != set(expected): raise SystemExit('vendor 内容与锁定的 registry 依赖不一致')
for name,checksum in expected.items():
    if json.loads((Path(sys.argv[2])/name/'.cargo-checksum.json').read_text())['package'] != checksum:
        raise SystemExit('vendor 包校验不一致: '+name)
PY
cache="$root/.local/downloads/ffmpeg-8.1.2.tar.xz"
if [[ -f "$cache" ]]; then
  cp "$cache" "$bundle/ffmpeg/ffmpeg-8.1.2.tar.xz"
else
  curl --http1.1 --fail --location --proto '=https' --retry 3 --retry-all-errors --max-time 180 --connect-timeout 30 --silent --show-error \
    https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz -o "$bundle/ffmpeg/ffmpeg-8.1.2.tar.xz"
fi
expected=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c
[[ $(shasum -a 256 "$bundle/ffmpeg/ffmpeg-8.1.2.tar.xz" | awk '{print $1}') == "$expected" ]] || { echo 'FFmpeg 源码校验失败' >&2; exit 1; }
mkdir -p "$(dirname "$cache")"
cp "$bundle/ffmpeg/ffmpeg-8.1.2.tar.xz" "$cache"
cp "$root/vendor/ffmpeg/BUILD-CONFIGURATION.txt" "$root/vendor/ffmpeg/licenses/COPYING.LGPLv2.1" "$root/scripts/build-ffmpeg-runtime.sh" "$bundle/ffmpeg/"
cat > "$bundle/README.md" <<'DOC'
# Lives 第三方对应源码

rust/vendor 包含本次 Cargo.lock 锁定的第三方 registry 包及其原始许可、构建说明；包含 MPL 等组件的对应源码。
ffmpeg 包含未经修改的 FFmpeg 8.1.2 上游源码压缩包、LGPL 许可、实际构建配置及构建脚本。源码压缩包的 SHA-256：
464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c

FFmpeg 脚本按项目目录结构写入 vendor/ffmpeg/macos-arm64；可在一个空目录建立 scripts/，放入脚本后执行。这些构建说明与 FFmpeg 脚本允许复制、修改及再分发。第三方源码仍遵循各自原许可。
Lives 使用外部 FFmpeg 可执行程序及动态库。为调试修改过的 LGPL 组件所需的逆向工程不受 Lives 终端许可限制。替换本地组件会使官方代码签名失效，可按 Apple 本地开发流程重新签名用于测试。
npm 生产依赖为 MIT / Apache-2.0，完整许可报告随 App 的 Legal 目录提供。
此资料不包含 Lives 或 LivesCore 的项目自有源码；旧开源版本的源码仍在原公开历史中。
DOC
name="Lives_${version}_third-party-source.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$work/$name" -C "$work" third-party
if [[ -e "$out/$name" ]]; then
  echo "已有第三方归档，保留原文件；清理未发布的准备目录后才能重新构建。" >&2
  exit 1
fi
mv "$work/$name" "$out/$name"
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
echo "第三方资料：$out/$name"
