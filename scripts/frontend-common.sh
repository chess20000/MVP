#!/bin/bash
# Shared paths and read-only dependency checks for the frontend scripts.
set -euo pipefail

FRONTEND_SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FRONTEND_ROOT="$(CDPATH= cd -- "$FRONTEND_SCRIPT_DIR/.." && pwd -P)"
FRONTEND_BUILD="$FRONTEND_ROOT/.build"
FRONTEND_DIST="$FRONTEND_ROOT/dist"
FRONTEND_APP='/Library/Input Methods/Squirrel.app'

frontend_fail() { printf '错误：%s\n' "$*" >&2; exit 1; }

[[ -f "$FRONTEND_ROOT/VERSION" ]] || frontend_fail '仓库根目录缺少 VERSION 文件。'
FRONTEND_VERSION="$(< "$FRONTEND_ROOT/VERSION")"
FRONTEND_VERSION="${FRONTEND_VERSION%$'\r'}"
[[ "$FRONTEND_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || frontend_fail 'VERSION 应为四段数字，例如 1.1.2.10。'
FRONTEND_GHOST_VERSION="${FRONTEND_VERSION##*.}"
FRONTEND_PACKAGE="$FRONTEND_DIST/Squirrel-Ghost-$FRONTEND_VERSION.pkg"

frontend_require_macos() {
  [[ "$(uname -s)" == 'Darwin' ]] || frontend_fail '这些脚本需要 macOS。'
}

frontend_resolve_template() {
  if [[ -n "${SQUIRREL_TEMPLATE:-}" ]]; then
    FRONTEND_TEMPLATE="$SQUIRREL_TEMPLATE"
  elif [[ -d "$FRONTEND_ROOT/vendor/Squirrel.app" ]]; then
    FRONTEND_TEMPLATE="$FRONTEND_ROOT/vendor/Squirrel.app"
  elif [[ -d "$FRONTEND_APP" ]]; then
    FRONTEND_TEMPLATE="$FRONTEND_APP"
    printf 'vendor/Squirrel.app 不存在，使用已安装的鼠须管作为应用模板：%s\n' "$FRONTEND_TEMPLATE" >&2
  else
    frontend_fail '缺少 vendor/Squirrel.app。请复制一份完整的鼠须管应用到该路径，或设置 SQUIRREL_TEMPLATE 指向现有应用；脚本不会联网下载。'
  fi
  [[ -d "$FRONTEND_TEMPLATE/Contents" ]] || frontend_fail "应用模板无效：$FRONTEND_TEMPLATE"
  FRONTEND_TEMPLATE="$(CDPATH= cd -- "$FRONTEND_TEMPLATE" && pwd -P)"
  local identifier
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FRONTEND_TEMPLATE/Contents/Info.plist" 2>/dev/null)" \
    || frontend_fail '无法读取应用模板的 Info.plist。'
  [[ "$identifier" == 'im.rime.inputmethod.Squirrel' ]] || frontend_fail "模板不是鼠须管应用：$identifier"
  FRONTEND_RUNTIME="$FRONTEND_TEMPLATE/Contents/Frameworks"
  [[ -f "$FRONTEND_RUNTIME/librime.1.dylib" ]] || frontend_fail '模板缺少 Contents/Frameworks/librime.1.dylib；请换用完整的已安装鼠须管应用。'
  [[ -f "$FRONTEND_RUNTIME/Sparkle.framework/Sparkle" ]] || frontend_fail '模板缺少 Sparkle.framework 运行库；请换用完整应用模板。'
}

frontend_check_build_dependencies() {
  frontend_require_macos
  frontend_resolve_template
  FRONTEND_ARCH="${TARGET_ARCH:-$(uname -m)}"
  case "$FRONTEND_ARCH" in arm64|x86_64) ;; *) frontend_fail 'TARGET_ARCH 只支持 arm64 或 x86_64。' ;; esac
  FRONTEND_SWIFTC="$(/usr/bin/xcrun --sdk macosx --find swiftc 2>/dev/null)" \
    || frontend_fail '缺少 Swift 编译器；请先安装 Xcode 或 Command Line Tools。'
  FRONTEND_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null)" \
    || frontend_fail '找不到 macOS SDK。'
  local header
  for header in rime_api.h rime_api_stdbool.h rime/key_table.h X11/keysym.h X11/keysymdef.h; do
    [[ -f "$FRONTEND_ROOT/native/include/$header" ]] || frontend_fail "缺少 native/include/$header；请先放入本地桥接头文件。"
  done
  [[ -f "$FRONTEND_ROOT/frontend/sources/Squirrel-Bridging-Header.h" ]] \
    || frontend_fail '缺少 frontend/sources/Squirrel-Bridging-Header.h；frontend/ 应为完整鼠须管源码。'
  [[ -f "$FRONTEND_ROOT/frontend/sources/Main.swift" ]] || frontend_fail '缺少 frontend/sources/Main.swift。'

  # Distributed apps often strip the development headers and module map.
  if [[ -n "${SPARKLE_SDK_FRAMEWORK:-}" ]]; then
    FRONTEND_SPARKLE_SDK="$SPARKLE_SDK_FRAMEWORK"
  elif [[ -d "$FRONTEND_ROOT/native/include/Sparkle.framework/Headers" && -d "$FRONTEND_ROOT/native/include/Sparkle.framework/Modules" ]]; then
    FRONTEND_SPARKLE_SDK="$FRONTEND_ROOT/native/include/Sparkle.framework"
  else
    FRONTEND_SPARKLE_SDK="$FRONTEND_RUNTIME/Sparkle.framework"
  fi
  [[ -f "$FRONTEND_SPARKLE_SDK/Headers/Sparkle.h" && -f "$FRONTEND_SPARKLE_SDK/Modules/module.modulemap" ]] \
    || frontend_fail 'Sparkle 模板没有开发头文件。请把匹配版本的 Headers/ 和 Modules/ 放入 native/include/Sparkle.framework/，或设置 SPARKLE_SDK_FRAMEWORK 指向本地完整开发框架。无需联网下载。'
  /usr/bin/xcrun lipo "$FRONTEND_RUNTIME/librime.1.dylib" -verify_arch "$FRONTEND_ARCH" \
    || frontend_fail "librime 不包含 $FRONTEND_ARCH 架构。"
  /usr/bin/xcrun lipo "$FRONTEND_RUNTIME/Sparkle.framework/Sparkle" -verify_arch "$FRONTEND_ARCH" \
    || frontend_fail "Sparkle 不包含 $FRONTEND_ARCH 架构。"
}
