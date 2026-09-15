#!/usr/bin/env python3
"""验证本仓库解析到仓库内的 Core；正式构建由本仓库的 Git 提交确定。

packages/LivesCore 是本仓库的内部模块，不依赖相邻仓库或旧共享目录。
SOURCE_REPO 是本仓库的远端，此文件之外没有其他绑定。
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

SOURCE_REPO = 'ohmyangboy/lives'
SOURCE_URL = f'https://github.com/{SOURCE_REPO}.git'
PRODUCT_ROOT = Path(__file__).resolve().parents[1]
CORE_RELATIVE = 'packages/LivesCore'


def git(repo, *args):
    return subprocess.check_output(['git', '--no-optional-locks', '-C', str(repo), *args], text=True).strip()


def git_toplevel(path):
    return Path(git(Path(path).resolve(), 'rev-parse', '--show-toplevel')).resolve()


def core_directory(root=PRODUCT_ROOT):
    core = Path(root).resolve() / CORE_RELATIVE
    if core.resolve() != core or not (core / 'Package.swift').is_file():
        raise ValueError('Core 必须是产品内真实存在的目录，不允许指向外部的链接')
    return core


def check_bindings(root=PRODUCT_ROOT):
    """Mac Helper 必须引用本产品的 Core；不读取其他产品或旧共享目录。"""
    root = Path(root).resolve()
    core = core_directory(root)
    service = root / 'native/LivePhotoService'
    manifest = (service / 'Package.swift').read_text()
    paths = re.findall(r'\.package\(path:\s*"([^"]+)"\)', manifest)
    if len(paths) != 1 or (service / paths[0]).resolve() != core:
        raise ValueError('Mac Helper 必须引用本产品的 packages/LivesCore')
    return core


def core_snapshot(root=PRODUCT_ROOT, release=False):
    root = Path(root).resolve()
    repo = git_toplevel(root)
    core = check_bindings(root)
    if git_toplevel(core) != repo:
        raise ValueError('Core 不得是嵌套 Git 仓库')
    if not (core / 'Sources/LivesCore/Resources/WatermarkAppIcon.png').is_file():
        raise ValueError('Core 缺少水印图标资源')
    if release:
        if git(repo, 'remote', 'get-url', 'origin') != SOURCE_URL:
            raise ValueError(f'正式发布来源必须是 {SOURCE_REPO}')
        if git(repo, 'status', '--porcelain', '--untracked-files=all'):
            raise ValueError('正式发布需要仓库处于干净提交')
    relative = core.relative_to(repo).as_posix()
    return {'path': relative, 'revision': git(repo, 'rev-parse', 'HEAD'),
            'tree': git(repo, 'rev-parse', f'HEAD:{relative}')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(core_snapshot(release=args.release), ensure_ascii=False))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))


if __name__ == '__main__':
    main()
