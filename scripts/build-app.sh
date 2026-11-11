#!/usr/bin/env bash
# 组装可运行的 iCut.app。
# 背景：本机只装了 Command Line Tools，没有 Xcode 的 Platforms 目录，
# SwiftPM（swift build / swift test）会在查询 PlatformPath 时直接失败，
# 所以这里用 swiftc + lipo 直接构建；本地开发验证与 GitHub Actions 共用这一条路径。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="iCut"
BUNDLE_ID="com.kevin.icut"
DEPLOYMENT_TARGET="13.0"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

universal=false
if [[ "${1:-}" == "--universal" ]]; then
  universal=true
fi

sources=()
while IFS= read -r file; do
  sources+=("$file")
done < <(find "$ROOT_DIR/src/iCut" -name '*.swift' -print)
if [[ ${#sources[@]} -eq 0 ]]; then
  echo "error: src/iCut 下没有找到 Swift 源文件" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

compile() {
  local arch="$1"
  local output="$2"
  echo "==> 编译 $arch"
  swiftc -O -target "${arch}-apple-macosx${DEPLOYMENT_TARGET}" -o "$output" "${sources[@]}"
}

if [[ "$universal" == true ]]; then
  compile arm64 "$BUILD_DIR/$APP_NAME-arm64"
  compile x86_64 "$BUILD_DIR/$APP_NAME-x86_64"
  echo "==> lipo 合并 universal"
  lipo -create -output "$BUILD_DIR/$APP_NAME" "$BUILD_DIR/$APP_NAME-arm64" "$BUILD_DIR/$APP_NAME-x86_64"
else
  compile "$(uname -m)" "$BUILD_DIR/$APP_NAME"
fi

echo "==> 组装 $APP_NAME.app"
# 只清理 dist 下本脚本自己的产物，不触碰其他路径
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> ad-hoc 签名"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --verbose=1 "$APP_DIR"

echo "==> 完成：$APP_DIR"
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"
