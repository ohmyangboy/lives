#!/usr/bin/env python3
"""为现有 Lives 统计脚本补充更新元数据；默认只检查，--apply 才修改。"""

import argparse
import ast
from datetime import datetime
import os
from pathlib import Path
import re
import shlex
import shutil
import tempfile


MARKER = "# LIVES_UPDATE_METADATA_V1"


def find_sync_lock(path):
    source = path.read_text(encoding="utf-8")
    assignments = re.findall(
        r'^LOCK_FILE=[\"\'](/run/[A-Za-z0-9_.-]*lives[A-Za-z0-9_.-]*\.lock)[\"\']\s*$',
        source, re.MULTILINE,
    )
    if len(assignments) != 1:
        raise ValueError("无法确认 Lives 独立发布锁；停止。请检查实际同步脚本的 LOCK_FILE。")
    if not re.search(r'exec\s+9\s*>\s*"\$LOCK_FILE"', source):
        raise ValueError("同步脚本没有预期的锁文件打开方式；停止，不修改。")
    if not re.search(r'flock\s+-n\s+9(?:\s|;)', source):
        raise ValueError("同步脚本没有预期的 flock 排他锁；停止，不修改。")
    return assignments[0]


def patched_source(source, lock_path):
    ast.parse(source)
    if MARKER in source:
        raise ValueError("脚本已有更新元数据补丁；无需重复应用。")
    required = [
        'OUTPUT = Path("/var/www/lives-download/lives-download-stats.json")',
        'VERSION_FILE = Path("/var/www/lives-download/.version")',
        'GITHUB_REPO = "ohmyangboy/lives"',
        'from pathlib import Path\n',
        '\nresult = {\n',
        '    "currentVersion": version,\n',
        'os.replace(str(tmp), str(OUTPUT))',
    ]
    for needle in required:
        if source.count(needle) != 1:
            raise ValueError("统计脚本结构与历史版本不一致；停止。缺失或重复：" + needle.strip())

    guard = '''
# LIVES_UPDATE_METADATA_V1
import fcntl
import re

# 和发布同步共用排他锁，也防止两次统计同时写 SQLite / JSON。
# 文件句柄保留到进程结束。不要删除或替换锁文件。
_lives_update_lock = open(LOCK_PATH, "a")
try:
    fcntl.flock(_lives_update_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print("Lives 同步或统计正在运行，本次跳过，保留上次 JSON。")
    raise SystemExit(0)

'''.replace("LOCK_PATH", repr(lock_path))
    source = source.replace('from pathlib import Path\n', 'from pathlib import Path\n' + guard, 1)

    metadata = '''
# 在同一发布锁内读取版本和文件，避免同步中途生成不一致的元数据。
if not isinstance(version, str) or not re.fullmatch(r"v?[0-9]+\\.[0-9]+\\.[0-9]+", version):
    raise RuntimeError("本地 .version 不是有效正式版本，保留上次 JSON。")
_lives_dmg = Path("/var/www/lives-download/Lives-latest.dmg")
_lives_hasher = hashlib.sha256()
_lives_size = 0
with _lives_dmg.open("rb") as _lives_file:
    while True:
        _lives_chunk = _lives_file.read(1024 * 1024)
        if not _lives_chunk:
            break
        _lives_hasher.update(_lives_chunk)
        _lives_size += len(_lives_chunk)
if _lives_size < 1024 * 1024:
    raise RuntimeError("Lives 安装包异常小，保留上次 JSON。")

'''
    source = source.replace('\nresult = {\n', '\n' + metadata + 'result = {\n', 1)
    source = source.replace('    "currentVersion": version,\n', '''    "currentVersion": version,
    "schemaVersion": 1,
    "downloadUrl": "https://download.1leaf.cc/Lives-latest.dmg",
    "sha256": _lives_hasher.hexdigest(),
    "size": _lives_size,
''', 1)
    compile(source, "lives-count-downloads", "exec")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="备份后应用；默认只检查")
    parser.add_argument("--stats-script", type=Path, default=Path("/usr/local/sbin/lives-count-downloads"))
    parser.add_argument("--sync-script", type=Path, help="实际持有发布锁的 Lives 同步脚本")
    parser.add_argument("--backup-dir", type=Path, default=Path("/root/lives-update-backups"))
    args = parser.parse_args()
    sync = args.sync_script
    if sync is None:
        candidates = [p for p in (
            Path("/usr/local/sbin/lives-sync-release"),
            Path("/usr/local/sbin/sync-lives-release"),
        ) if p.is_file()]
        if len(candidates) != 1:
            raise ValueError("无法唯一确定同步脚本；用 --sync-script 指定真实路径。")
        sync = candidates[0]
    if args.stats_script.is_symlink():
        raise ValueError("统计脚本是符号链接；停止，避免覆盖未知目标。")
    lock_path = find_sync_lock(sync)
    original = args.stats_script.read_text(encoding="utf-8")
    candidate = patched_source(original, lock_path)
    info = args.stats_script.stat()
    print("统计脚本：", args.stats_script)
    print("同步脚本：", sync)
    print("共用发布锁：", lock_path)
    print("将增加 schemaVersion、downloadUrl、sha256、size；保留原统计逻辑。")
    if not args.apply:
        print("检查通过，尚未修改。添加 --apply 才会备份并应用。")
        return

    args.backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(
        prefix=datetime.now().strftime("%Y%m%d-%H%M%S-"), dir=str(args.backup_dir),
    ))
    shutil.copy2(str(args.stats_script), str(backup / "lives-count-downloads"))
    output = Path("/var/www/lives-download/lives-download-stats.json")
    if output.is_file():
        shutil.copy2(str(output), str(backup / "lives-download-stats.json"))
    fd, name = tempfile.mkstemp(prefix=".lives-stats-", dir=str(args.stats_script.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(candidate)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, info.st_mode & 0o7777)
        if (os.stat(name).st_uid, os.stat(name).st_gid) != (info.st_uid, info.st_gid):
            os.chown(name, info.st_uid, info.st_gid)
        if args.stats_script.read_text(encoding="utf-8") != original:
            raise ValueError("检查后统计脚本又发生变化；停止，未覆盖。")
        os.replace(name, str(args.stats_script))
    finally:
        if os.path.exists(name):
            os.unlink(name)
    print("已应用，备份目录：", backup)
    print("回滚脚本命令（先停止统计 timer/service）：")
    print("cp -p {} {}".format(
        shlex.quote(str(backup / "lives-count-downloads")),
        shlex.quote(str(args.stats_script)),
    ))
    print("尚未运行统计服务，尚未修改公网 JSON。")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, SyntaxError) as error:
        raise SystemExit("停止：" + str(error))
