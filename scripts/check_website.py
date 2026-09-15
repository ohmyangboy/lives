#!/usr/bin/env python3
"""校验官网构建输出可以公开：只允许静态格式，不允许占位符、本地路径、source map 或密钥。

本地在 website/ 下运行 `npm run check`；CI 在 Pages 部署前调用同一入口。
"""
import argparse
from pathlib import Path

SAFE_SUFFIXES = {'.html', '.css', '.js', '.json', '.svg', '.png', '.jpg', '.jpeg', '.webp',
                 '.gif', '.mp4', '.mov', '.webm', '.ico', '.woff', '.woff2', '.txt', '.webmanifest'}
TEXT_SUFFIXES = {'.html', '.css', '.js', '.json', '.txt', '.svg'}
FORBIDDEN = ('__LIVES_VERSION__', '__LIVES_DOWNLOAD_URL__', '/Users/', 'sourceMappingURL=', 'PRIVATE KEY-----')


def validate_site(root):
    root = Path(root)
    files = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError(f'官网不允许符号链接：{path.name}')
        if path.is_dir():
            continue
        relative = path.relative_to(root)
        name = relative.as_posix()
        suffix = path.suffix.lower()
        if any(part.startswith('.') for part in relative.parts) or suffix not in SAFE_SUFFIXES:
            raise ValueError(f'官网包含未获准公开的文件：{name}')
        if suffix in TEXT_SUFFIXES:
            text = path.read_text()
            if any(marker in text for marker in FORBIDDEN):
                raise ValueError(f'官网存在占位符、本地路径、source map 或密钥：{name}')
        files[name] = path.stat().st_size
    if 'index.html' not in files:
        raise ValueError('官网缺少 index.html')
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', default='dist')
    args = parser.parse_args()
    try:
        files = validate_site(args.root)
    except (ValueError, OSError) as error:
        raise SystemExit(f'官网校验未通过：{error}')
    print(f'官网校验通过：{len(files)} 个文件')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
