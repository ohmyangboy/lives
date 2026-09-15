#!/usr/bin/env bash
set -euo pipefail
echo "新版本仅提供第三方对应源码；请运行 npm run source:build。历史 GPL 版本使用对应历史 tag 的构建脚本。" >&2
exit 1
