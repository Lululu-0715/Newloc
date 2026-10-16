#!/usr/bin/env bash
#
# 把 Go Core 编译成 iOS 可用的静态库（设备 + 模拟器两个架构）。
#
# 前置条件：macOS + Xcode Command Line Tools + Go 1.23+
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT/Core"
BUILD_DIR="$CORE_DIR/build"
MIN_IOS_VERSION="15.0"

usage() {
  cat <<'USAGE'
用法: Scripts/build-core.sh

把 Core/ 下的 Go 代码编译成静态库：
  Core/build/iphoneos/liblocationcore.a         设备（arm64）
  Core/build/iphonesimulator/liblocationcore.a  模拟器（arm64 + x86_64 通用库）

模拟器库必须是通用库：Apple Silicon 上的模拟器跑 arm64，
Intel Mac 上的模拟器跑 x86_64，只编一个架构会在另一种机器上链接失败。
如果脚本里没有该架构的 .o 文件，说明你装了旧版本的脚本。

同时导出 C 头文件到 Core/locationcore.h 供 Swift 桥接层使用。
USAGE
}

require_command() {
  local name="$1" hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "缺少命令: $name" >&2
    echo "$hint" >&2
    exit 1
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

require_command xcrun "请安装 Xcode 及其命令行工具。"
require_command go "请安装 Go 1.23 或更高版本。"

build_slice() {
  local sdk="$1"
  local goarch="$2"
  local clang_arch="$3"
  local min_flag="$4"
  local output="$5"
  local sdk_path

  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

  CGO_ENABLED=1 \
  CGO_CFLAGS="-arch $clang_arch -isysroot $sdk_path $min_flag" \
  CGO_LDFLAGS="-arch $clang_arch -isysroot $sdk_path $min_flag" \
  GOOS=ios GOARCH="$goarch" \
  go build -buildmode=c-archive -trimpath -ldflags="-s -w" -o "$output" .
}

# 把多个单架构静态库合成一个通用库。
#
# 首选 lipo（合成通用二进制最标准的方式）。但某些受限环境——企业 MDM 策略、
# 沙箱、部分 CI——会禁止 lipo 改写 Mach-O，此时退回 libtool：它是静态归档器，
# 合并多架构归档的效果等价（Xcode 自己产出 .a 用的就是它）。
merge_slices() {
  local output="$1"
  shift

  rm -f "$output" "$output.lipo"

  if xcrun lipo -create "$@" -output "$output" 2>/dev/null; then
    return 0
  fi

  if xcrun libtool -static -o "$output" "$@" 2>/dev/null; then
    echo "    注意：lipo 不可用，已改用 libtool 合并"
    return 0
  fi

  echo "架构合并失败: $output" >&2
  return 1
}

echo "==> 清理旧产物"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/iphoneos" "$BUILD_DIR/iphonesimulator"

cd "$CORE_DIR"
echo "==> 同步 Go 模块依赖"
go mod download

echo "==> 编译设备静态库 (iphoneos/arm64)"
build_slice iphoneos arm64 arm64 \
  "-miphoneos-version-min=$MIN_IOS_VERSION" \
  "$BUILD_DIR/iphoneos/liblocationcore.a"

echo "==> 编译模拟器静态库 (iphonesimulator/arm64 + x86_64)"
build_slice iphonesimulator arm64 arm64 \
  "-mios-simulator-version-min=$MIN_IOS_VERSION" \
  "$BUILD_DIR/iphonesimulator/liblocationcore-arm64.a"
build_slice iphonesimulator amd64 x86_64 \
  "-mios-simulator-version-min=$MIN_IOS_VERSION" \
  "$BUILD_DIR/iphonesimulator/liblocationcore-x86_64.a"

echo "==> 合成模拟器通用静态库"
merge_slices "$BUILD_DIR/iphonesimulator/liblocationcore.a" \
  "$BUILD_DIR/iphonesimulator/liblocationcore-arm64.a" \
  "$BUILD_DIR/iphonesimulator/liblocationcore-x86_64.a"
rm -f \
  "$BUILD_DIR/iphonesimulator/liblocationcore-arm64.a" \
  "$BUILD_DIR/iphonesimulator/liblocationcore-arm64.h" \
  "$BUILD_DIR/iphonesimulator/liblocationcore-x86_64.a" \
  "$BUILD_DIR/iphonesimulator/liblocationcore-x86_64.h"

echo "==> 导出 C 头文件"
cp "$BUILD_DIR/iphoneos/liblocationcore.h" "$CORE_DIR/locationcore.h"

test -s "$BUILD_DIR/iphoneos/liblocationcore.a"
test -s "$BUILD_DIR/iphonesimulator/liblocationcore.a"
test -s "$CORE_DIR/locationcore.h"

echo "完成：设备与模拟器静态库均已生成"
echo "     设备  : $(xcrun lipo -archs "$BUILD_DIR/iphoneos/liblocationcore.a")"
echo "     模拟器: $(xcrun lipo -archs "$BUILD_DIR/iphonesimulator/liblocationcore.a")"
