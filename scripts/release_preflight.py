#!/usr/bin/env python3
"""正式版本、发布来源与仓库内 Core 检查；不会创建 tag、提交或上传。"""
import json
import os
import re
import subprocess
import tomllib
from pathlib import Path

from core_dependency import SOURCE_REPO, SOURCE_URL, core_snapshot, git_toplevel

ROOT = Path(__file__).resolve().parents[1]
REPO = git_toplevel(ROOT)


def check():
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=REPO, text=True).strip()
    if git('remote', 'get-url', 'origin') != SOURCE_URL:
        raise ValueError(f'origin 不是预期的 {SOURCE_REPO}，停止发布')
    if git('status', '--porcelain', '--untracked-files=all'):
        raise ValueError('正式发布需要仓库处于干净提交')
    if os.environ.get('LIVES_CORE_MODE', 'locked') != 'locked' or os.environ.get('LIVES_CORE_PATH'):
        raise ValueError('正式发布禁止本地 Core 覆盖')
    app = json.loads((ROOT / 'package.json').read_text())
    version = app['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('此正式发布入口只接受 x.y.z 版本')
    if tuple(map(int, version.split('.'))) < (0, 1, 15):
        raise ValueError('版本号必须从 0.1.15 或以后继续，不覆盖已发布的历史版本')
    tauri = json.loads((ROOT / 'src-tauri/tauri.conf.json').read_text())
    cargo = tomllib.loads((ROOT / 'src-tauri/Cargo.toml').read_text())
    website = json.loads((ROOT / 'website/package.json').read_text())
    values = [tauri['version'], tauri['bundle']['macOS']['bundleVersion'], cargo['package']['version'], website['version']]
    if any(v != version for v in values) or app.get('license') != 'GPL-3.0-only':
        raise ValueError('应用/官网/原生版本或许可标记不一致')
    head = git('rev-parse', 'HEAD')
    tag = f'mac/v{version}'
    tagged = subprocess.run(['git', 'rev-parse', '--verify', f'{tag}^{{commit}}'], cwd=REPO, capture_output=True, text=True)
    if tagged.returncode or tagged.stdout.strip() != head:
        raise ValueError(f'正式发布需要 {tag} 指向当前提交')
    pin = core_snapshot(REPO, release=True)
    return {'version': version, 'tag': f'v{version}', 'appCommit': head, 'core': pin}


if __name__ == '__main__':
    try:
        print(json.dumps(check(), ensure_ascii=False))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
