#!/usr/bin/env python3
"""检查实际签名中的照片权限，不能只检查源 plist 或签名是否有效。"""

import plistlib
import subprocess
import sys
from pathlib import Path

PHOTO_ENTITLEMENT = "com.apple.security.personal-information.photos-library"


def verify(target: Path) -> None:
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(target)],
        check=True,
    )
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(target)],
        capture_output=True,
        check=True,
    )
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    if entitlements.get(PHOTO_ENTITLEMENT) is not True:
        raise ValueError(f"{target} 的签名缺少 {PHOTO_ENTITLEMENT}=true")
    print(f"照片签名权限检查通过：{target}")


def main() -> int:
    if len(sys.argv) < 2:
        print("用法：python3 scripts/verify-photo-permissions.py <App 或可执行文件> [...]", file=sys.stderr)
        return 2
    try:
        for argument in sys.argv[1:]:
            target = Path(argument)
            verify(target)
            if (target / "Contents/MacOS/live-collage").exists():
                verify(target / "Contents/Resources/LiveCollagePhotosHelper.app")
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"照片签名权限检查失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
