#!/usr/bin/env bash
# 组装可运行的 iCut.app。
# 背景：本机只装了 Command Line Tools，没有 Xcode 的 Platforms 目录，
# SwiftPM（swift build / swift test）会在查询 PlatformPath 时直接失败，
# 所以这里用 swiftc + lipo 直接构建；本地开发验证与 GitHub Actions 共用这一条路径。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="iCut"
BUNDLE_ID="com.icut.app"
DEPLOYMENT_TARGET="13.0"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

universal=false
make_dmg=false
for arg in "$@"; do
  case "$arg" in
    --universal) universal=true ;;
    --dmg) make_dmg=true ;;
  esac
done

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
if [[ -f "$ROOT_DIR/resources/$APP_NAME.icns" ]]; then
  cp "$ROOT_DIR/resources/$APP_NAME.icns" "$APP_DIR/Contents/Resources/$APP_NAME.icns"
fi
for icon in MenuBarIcon.png MenuBarIcon@2x.png; do
  if [[ -f "$ROOT_DIR/resources/$icon" ]]; then
    cp "$ROOT_DIR/resources/$icon" "$APP_DIR/Contents/Resources/$icon"
  fi
done

echo "==> 签名"
# 有本地开发证书就用它：ad-hoc 每次重建都会改变 cdhash，屏幕录制授权会反复失效
SIGN_IDENTITY="iCut Dev Signer"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  SIGN_IDENTITY="-"
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --verbose=1 "$APP_DIR"

echo "==> 完成：$APP_DIR"
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ "$make_dmg" == true ]]; then
  echo "==> 生成 dmg"
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/resources/Info.plist")"
  DMG_STAGE="$BUILD_DIR/dmg"
  DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
  # 卷内附 Applications 快捷方式，用户拖一下就能装入
  rm -rf "$DMG_STAGE"
  mkdir -p "$DMG_STAGE"
  cp -R "$APP_DIR" "$DMG_STAGE/"
  ln -s /Applications "$DMG_STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  hdiutil verify "$DMG_PATH" >/dev/null
  echo "==> 完成：$DMG_PATH"
fi
