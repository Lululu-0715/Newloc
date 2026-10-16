#!/usr/bin/env python3
"""版本号维护。

用法：
    python3 Scripts/bump-version.py                 打印当前版本号
    python3 Scripts/bump-version.py --bump          末位 +1 并写回 project.yml
    python3 Scripts/bump-version.py --set 1.2.3     直接设定版本号
    python3 Scripts/bump-version.py --show-build    打印 CURRENT_PROJECT_VERSION
    python3 Scripts/bump-version.py --set-build 7   回写 CURRENT_PROJECT_VERSION

版本号的唯一事实来源是 `project.yml` 的 `MARKETING_VERSION`：

  - Xcode 构建时由 Info.plist 的 `$(MARKETING_VERSION)` 注入到 App，
    在「设置 → 关于 → 应用版本」里显示；
  - 导出的 IPA 文件名也用它（`Newloc-1.0.1-unsigned.ipa`）。

注意：App 显示名（桌面图标）恒为 `Newloc`，**不带**版本号。想让多个自签构建
可区分，靠的是 IPA 文件名和 App 内的版本号，而不是图标名字。

`--bump` 会连带自增 `CURRENT_PROJECT_VERSION`（Xcode 内部 build 号）。
所以构建失败时两个号都得回退，否则失败的那次会白白吃掉一个 build 号，
`--show-build` / `--set-build` 就是给 `build.sh` 的回滚逻辑用的。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT_YML = ROOT / "project.yml"

VERSION_PATTERN = re.compile(r'(MARKETING_VERSION:\s*")([^"]+)(")')
BUILD_PATTERN = re.compile(r'(CURRENT_PROJECT_VERSION:\s*")(\d+)(")')


def read_current_version() -> str:
    text = PROJECT_YML.read_text(encoding="utf-8")
    match = VERSION_PATTERN.search(text)
    if not match:
        raise SystemExit("无法从 project.yml 读出 MARKETING_VERSION")
    return match.group(2)


def bump_patch(version: str) -> str:
    """末位 +1。位数不足三位时补零（1.0 → 1.0.1，1 → 1.0.1）。"""
    parts = version.split(".")
    while len(parts) < 3:
        parts.append("0")
    parts = parts[:3]
    try:
        parts[2] = str(int(parts[2]) + 1)
    except ValueError:
        raise SystemExit(f"版本号末位不是数字，无法自增：{version}")
    return ".".join(parts)


def read_current_build() -> str:
    text = PROJECT_YML.read_text(encoding="utf-8")
    match = BUILD_PATTERN.search(text)
    if not match:
        raise SystemExit("无法从 project.yml 读出 CURRENT_PROJECT_VERSION")
    return match.group(2)


def write_version(version: str, bump_build_number: bool) -> None:
    text = PROJECT_YML.read_text(encoding="utf-8")

    text, count = VERSION_PATTERN.subn(rf"\g<1>{version}\g<3>", text, count=1)
    if count != 1:
        raise SystemExit("写回 MARKETING_VERSION 失败")

    if bump_build_number:
        match = BUILD_PATTERN.search(text)
        if not match:
            raise SystemExit("无法从 project.yml 读出 CURRENT_PROJECT_VERSION")
        next_build = str(int(match.group(2)) + 1)
        text = BUILD_PATTERN.sub(rf"\g<1>{next_build}\g<3>", text, count=1)

    PROJECT_YML.write_text(text, encoding="utf-8")


def write_build(build: str) -> None:
    text = PROJECT_YML.read_text(encoding="utf-8")
    text, count = BUILD_PATTERN.subn(rf"\g<1>{build}\g<3>", text, count=1)
    if count != 1:
        raise SystemExit("写回 CURRENT_PROJECT_VERSION 失败")
    PROJECT_YML.write_text(text, encoding="utf-8")


def main(argv: list[str]) -> int:
    if not argv:
        print(read_current_version())
        return 0

    command = argv[0]

    if command == "--bump":
        current = read_current_version()
        next_version = bump_patch(current)
        write_version(next_version, bump_build_number=True)
        print(next_version)
        return 0

    if command == "--set":
        if len(argv) != 2:
            print("--set 需要一个版本号参数，例如 --set 1.2.3", file=sys.stderr)
            return 2
        write_version(argv[1], bump_build_number=False)
        print(argv[1])
        return 0

    if command == "--show-build":
        print(read_current_build())
        return 0

    if command == "--set-build":
        if len(argv) != 2 or not argv[1].isdigit():
            print("--set-build 需要一个非负整数，例如 --set-build 7", file=sys.stderr)
            return 2
        write_build(argv[1])
        print(argv[1])
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
