#!/usr/bin/env python3
"""使用与 Tauri 相同的安装窗口配置，封装已签名（或已公证）的 App。"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def eject_create_dmg_mounts() -> None:
    """清理 create-dmg 在 Finder 占用时遗留的临时挂载。"""
    info = subprocess.run(["hdiutil", "info"], capture_output=True, text=True, check=False).stdout
    devices = {
        line.split()[0]
        for line in info.splitlines()
        if "/Volumes/dmg." in line and line.split()
    }
    for device in devices:
        subprocess.run(["hdiutil", "detach", device, "-force"], check=False)


def eject_conflicting_volumes() -> None:
    """构建前清理会干扰 create-dmg 的挂载卷。

    create-dmg 通过 AppleScript 驱动 Finder 操作名为 "Lives" 的卷；若用户手动
    挂载过任何 Lives DMG（卷名同为 "Lives"，例如安装/查看旧版本），脚本会定位
    到错误的卷而以 exit 16 失败。这些卷只可能是本应用自己的镜像，可安全弹出。
    """
    volumes = Path("/Volumes")
    if not volumes.is_dir():
        return
    for volume in volumes.iterdir():
        if volume.name == "Lives" or volume.name.startswith(("Lives ", "dmg.", "rw.")):
            device = subprocess.run(
                ["hdiutil", "info"], capture_output=True, text=True, check=False
            ).stdout
            for line in device.splitlines():
                if str(volume) in line and line.split() and line.split()[0].startswith("/dev/"):
                    subprocess.run(["hdiutil", "detach", line.split()[0], "-force"], check=False)
            # 按卷名直接弹出（覆盖无法回溯设备节点的情况）
            subprocess.run(["hdiutil", "detach", str(volume), "-force"], check=False)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("用法：python3 scripts/build-dmg.py <Lives.app> <输出.dmg>")
    builder = shutil.which("create-dmg")
    if not builder:
        raise SystemExit("缺少 create-dmg，请先安装；不会降级生成没有安装提示的镜像。")
    app, output = (Path(argument).resolve() for argument in sys.argv[1:])
    if not (app / "Contents/Info.plist").is_file():
        raise SystemExit(f"无效的应用包：{app}")
    if output.suffix != ".dmg":
        raise SystemExit("输出路径必须以 .dmg 结尾")
    configuration = json.loads((ROOT / "src-tauri/tauri.conf.json").read_text())
    layout = configuration["bundle"]["macOS"]["dmg"]
    background = ROOT / "src-tauri" / layout["background"]
    if not background.is_file():
        raise SystemExit("缺少安装背景，请运行 swift scripts/render-dmg-background.swift")
    subprocess.run([sys.executable, str(ROOT / "scripts/verify-photo-permissions.py"), str(app)], check=True)
    eject_conflicting_volumes()
    output.parent.mkdir(parents=True, exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix="lives-dmg-", dir=output.parent))
    try:
        content = workspace / "content"
        content.mkdir()
        shutil.copytree(app, content / app.name, symlinks=True)
        image = workspace / "installer.dmg"
        window = layout["windowSize"]
        position = layout["windowPosition"]
        app_position = layout["appPosition"]
        folder_position = layout["applicationFolderPosition"]
        create_result = subprocess.run([
            builder, "--volname", "Lives", "--volicon", str(ROOT / "src-tauri/icons/icon.icns"),
            "--background", str(background),
            "--window-pos", str(position["x"]), str(position["y"]),
            "--window-size", str(window["width"]), str(window["height"]),
            "--icon-size", "128", "--text-size", "16",
            "--icon", app.name, str(app_position["x"]), str(app_position["y"]),
            "--hide-extension", app.name,
            "--app-drop-link", str(folder_position["x"]), str(folder_position["y"]),
            "--no-internet-enable", str(image), str(content),
        ], check=False)
        if create_result.returncode:
            # create-dmg exits 16 when its final detach races Finder. The
            # image and .DS_Store are already complete at that point; eject
            # the stale mount, then verify the image before accepting it.
            if create_result.returncode == 16 and image.is_file():
                eject_create_dmg_mounts()
            else:
                raise subprocess.CalledProcessError(create_result.returncode, create_result.args)
        subprocess.run(["hdiutil", "verify", str(image)], check=True)
        image.replace(output)
    except Exception:
        print(f"安装镜像打包失败，保留中间文件以便排查：{workspace}", file=sys.stderr)
        raise
    else:
        shutil.rmtree(workspace)
        print(f"已生成带拖拽安装提示的镜像：{output}")


if __name__ == "__main__":
    main()
