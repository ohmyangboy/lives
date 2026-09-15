#!/usr/bin/env python3
"""本机准备、发布和验收；重复 publish 可继续同一份已冻结的产物。

本仓库同时承载 Mac 源码与官网源码，对外远端即 SOURCE_URL。官网由
.github/workflows/pages.yml 从 website/ 源码构建部署，不在本工具内推送。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

from release_preflight import check, ROOT
from core_dependency import SOURCE_REPO, SOURCE_URL

DOWNLOAD = 'https://download.1leaf.cc/Lives-latest.dmg'
STATS = 'https://download.1leaf.cc/lives-download-stats.json'
STAGE = ROOT / '.local/publication'


def run(*args, cwd=ROOT, env=None):
    return subprocess.check_output([str(x) for x in args], cwd=cwd, env=env, text=True).strip()


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def tree(root):
    result = {}
    for p in sorted(Path(root).rglob('*')):
        if p.is_symlink():
            raise ValueError(f'公开资料不允许符号链接：{p.name}')
        if p.is_file():
            result[p.relative_to(root).as_posix()] = sha(p)
    return result


def validate_archive(path):
    with tarfile.open(path, 'r:gz') as archive:
        members = archive.getmembers()
        names = set()
        for m in members:
            p = PurePosixPath(m.name)
            if p.is_absolute() or '..' in p.parts or not (m.isfile() or m.isdir()):
                raise ValueError('第三方归档有不安全路径、链接或特殊文件')
            if m.name in names:
                raise ValueError('第三方归档存在重复路径')
            names.add(m.name)
            if p.parts[0] != 'third-party' or (len(p.parts) > 1 and p.parts[1] not in {'rust', 'ffmpeg', 'README.md'}):
                raise ValueError('第三方归档存在非白名单内容')
        required = {'third-party/README.md', 'third-party/ffmpeg/ffmpeg-8.1.2.tar.xz', 'third-party/ffmpeg/COPYING.LGPLv2.1'}
        if not required <= names or not any(n.startswith('third-party/rust/vendor/') for n in names):
            raise ValueError('第三方归档缺少依赖源码')


def asset_names(version):
    return [f'Lives_{version}_aarch64.dmg', f'Lives_{version}_aarch64.dmg.sha256',
            f'Lives_{version}_third-party-source.tar.gz', f'Lives_{version}_third-party-source.tar.gz.sha256']


def latest():
    return json.loads(run('gh', 'api', f'repos/{SOURCE_REPO}/releases/latest'))


def save_manifest(data):
    data['files'] = tree(STAGE / 'payload')
    (STAGE / 'manifest.json').write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')


def verify_receipt(snapshot, source):
    receipt = json.loads((source / 'build-receipt.json').read_text())
    if any(receipt.get(k) != value for k, value in snapshot.items()):
        raise ValueError('签名构建记录与当前 App/Core 提交不一致')
    expected = {name: sha(source / name) for name in asset_names(snapshot['version'])}
    if receipt.get('files') != expected:
        raise ValueError('产物已变化，不能使用原签名构建记录')


def prepare(notes, build):
    snapshot = check()
    if STAGE.exists():
        raise ValueError('已有冻结资料；先验收或人工归档 .local/publication，避免覆盖未完成发布')
    if not notes or not Path(notes).is_file() or not Path(notes).read_text().strip():
        raise ValueError('使用 --notes 指定已审查的公开发布说明')
    if build:
        run('bash', 'scripts/notarize-and-package.sh', env={**os.environ, 'LIVES_CORE_MODE': 'locked'})
    if check() != snapshot:
        raise ValueError('构建期间源码或锁定版本变化')
    version = snapshot['version']
    source = ROOT / 'release' / snapshot['tag']
    verify_receipt(snapshot, source)
    for name in asset_names(version):
        p = source / name
        if p.is_symlink() or not p.is_file() or not p.stat().st_size:
            raise ValueError(f'缺少正式产物：{name}')
    dmg = source / asset_names(version)[0]
    run('codesign', '--verify', '--verbose=2', dmg)
    run('xcrun', 'stapler', 'validate', dmg)
    for name in asset_names(version)[::2]:
        if (source / (name + '.sha256')).read_text().split()[0] != sha(source / name):
            raise ValueError(f'产物校验和不匹配：{name}')
    validate_archive(source / asset_names(version)[2])
    payload = STAGE / 'payload'
    (payload / 'assets').mkdir(parents=True)
    for name in asset_names(version):
        shutil.copy2(source / name, payload / 'assets' / name)
    (payload / 'release-notes.md').write_text(Path(notes).read_text())
    save_manifest({**snapshot, 'kind': 'release'})
    print(f'准备完成，尚未公开：{STAGE}')


def load():
    data = json.loads((STAGE / 'manifest.json').read_text())
    if not re.fullmatch(r'\d+\.\d+\.\d+', data['version']):
        raise ValueError('无效版本')
    if data.get('kind') != 'release':
        raise ValueError('无效准备类型')
    if data['tag'] != 'v' + data['version'] or tree(STAGE / 'payload') != data['files']:
        raise ValueError('冻结资料已变化；停止上传')
    if run('git', 'rev-parse', 'HEAD') != data['appCommit'] or run('git', 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('源码已改变；请回到准备时的干净提交')
    if check()['core'] != data['core']:
        raise ValueError('Core 锁定版本已变化')
    if set(tree(STAGE / 'payload/assets')) != set(asset_names(data['version'])):
        raise ValueError('上传资产必须严格匹配白名单')
    validate_archive(STAGE / 'payload/assets' / asset_names(data['version'])[2])
    return data


def public_guard():
    """发布入口只在本仓库使用：确认远端身份、公开状态与部署前置配置。"""
    if os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN'):
        raise ValueError('请使用 gh auth login 的本机用户授权；此入口不使用 CI token')
    if run('git', 'remote', 'get-url', 'origin') != SOURCE_URL:
        raise ValueError(f'发布工具必须在预期的仓库使用：{SOURCE_REPO}')
    info = json.loads(run('gh', 'repo', 'view', SOURCE_REPO, '--json', 'visibility,defaultBranchRef'))
    if info['visibility'] != 'PUBLIC' or info['defaultBranchRef']['name'] != 'main':
        raise ValueError('仓库可见性或默认分支不符合预期（应为公开且默认分支为 main）')
    variables = json.loads(run('gh', 'api', f'repos/{SOURCE_REPO}/actions/variables'))['variables']
    values = {v['name']: v['value'] for v in variables}
    if any(values.get(k) != 'true' for k in ('LIVES_RELEASE_SYNC_ENABLED', 'LIVES_SERVER_DEPLOY_ENABLED')):
        raise ValueError('发布同步或官网服务器部署未启用')
    secrets = json.loads(run('gh', 'api', f'repos/{SOURCE_REPO}/actions/secrets'))['secrets']
    if 'LIVES_SERVER_KNOWN_HOSTS' not in {s['name'] for s in secrets}:
        raise ValueError('尚未配置经核验的服务器 known_hosts Secret')


def release_info(tag):
    # 列表中不存在才创建；鉴权/网络错误不能当作不存在。
    releases = json.loads(run('gh', 'api', '--paginate', '--slurp', f'repos/{SOURCE_REPO}/releases?per_page=100'))
    return next((r for page in releases for r in page if r['tag_name'] == tag), None)


def verify_assets(data, info, upload=False):
    names = asset_names(data['version'])
    existing = {a['name']: a for a in info['assets']}
    if set(existing) - set(names):
        raise ValueError('远端已有额外资产，需要人工核查')
    with tempfile.TemporaryDirectory(prefix='lives-release-verify-') as temp:
        for name in names:
            local = STAGE / 'payload/assets' / name
            if name in existing:
                run('gh', 'release', 'download', data['tag'], '--repo', SOURCE_REPO, '--pattern', name, '--dir', temp)
                if sha(Path(temp) / name) != sha(local):
                    raise ValueError(f'远端资产内容不同，禁止覆盖：{name}')
            elif upload and info['draft']:
                run('gh', 'release', 'upload', data['tag'], local, '--repo', SOURCE_REPO)
            else:
                raise ValueError(f'远端缺少资产：{name}')


def publish():
    data = load()
    public_guard()
    current = latest()
    if tuple(map(int, current['tag_name'].lstrip('v').split('.'))) > tuple(map(int, data['version'].split('.'))):
        raise ValueError('已有更新正式版，禁止回退 latest')
    info = release_info(data['tag'])
    if info is None:
        run('gh', 'release', 'create', data['tag'], '--repo', SOURCE_REPO, '--target', 'main', '--draft',
            '--title', f'Lives {data["tag"]}', '--notes-file', STAGE / 'payload/release-notes.md')
        info = release_info(data['tag'])
    if info['prerelease']:
        raise ValueError('同名 tag 是预发布，停止处理')
    verify_assets(data, info, upload=True)
    info = release_info(data['tag'])
    verify_assets(data, info)
    if info['draft']:
        run('gh', 'release', 'edit', data['tag'], '--repo', SOURCE_REPO, '--draft=false', '--latest')
    verify_download(data)
    print('Release 已发布。官网由 .github/workflows/pages.yml 从 website/ 源码部署；'
          '服务器同步是异步的，稍后运行 npm run release:verify 验收。')


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={'Cache-Control': 'no-cache'}), timeout=60) as response:
        return response.read()


def verify_download(data):
    name = asset_names(data['version'])[0]
    expected = data['files']['assets/' + name]
    meta = json.loads(fetch(STATS))
    # 服务器字段结构保留原协议；版本/hash/size 任一不匹配均不能推进验收。
    version = str(meta.get('currentVersion', '')).lstrip('v')
    size = (STAGE / 'payload/assets' / name).stat().st_size
    if version != data['version'] or meta.get('sha256') != expected or meta.get('size') != size:
        raise ValueError('服务器元数据尚未同步或校验失败，稍后重试 publish/verify')
    if hashlib.sha256(fetch(DOWNLOAD)).hexdigest() != expected:
        raise ValueError('服务器 DMG SHA-256 不一致')


def verify():
    data = load()
    current = latest()
    if current['tag_name'] != data['tag']:
        raise ValueError('公开 latest 与冻结版本不一致')
    verify_assets(data, current)
    verify_download(data)
    for host in ('https://ohmyangboy.github.io/lives/', 'https://lives.1leaf.cc/'):
        body = fetch(host).decode('utf-8', 'replace')
        if f'v{data["version"]}' not in body:
            raise ValueError(f'官网尚未部署当前版本：{host}')
    print('公开 Release / 下载与官网验收通过')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['prepare', 'publish', 'verify'])
    p.add_argument('--notes', help='公开发布说明文件')
    p.add_argument('--build', action='store_true', help='先构建签名并在线公证，需本机钥匙串')
    args = p.parse_args()
    if args.command == 'prepare':
        prepare(args.notes, args.build)
    elif args.command == 'publish':
        publish()
    else:
        verify()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'发布未完成：{error}')
