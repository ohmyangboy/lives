#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
case "${1:-local}" in
  local) python3 "$script_dir/core_dependency.py" ;;
  locked) python3 "$script_dir/core_dependency.py" --release ;;
  *) echo "用法：$0 local|locked" >&2; exit 2 ;;
esac
