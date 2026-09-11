#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/frontend-common.sh"

case "${1:-}" in
  --help|-h)
    cat <<'HELP'
用法：scripts/build-frontend.sh [--check]
构建 frontend/，输出 .build/Squirrel；不安装或重载输入法。
--check  仅检查源码、本机编译器、模板和头文件，不写入文件。
可选环境变量：SQUIRREL_TEMPLATE、SPARKLE_SDK_FRAMEWORK、TARGET_ARCH。
默认使用 vendor/Squirrel.app；不存在时回退到已安装的鼠须管。
HELP
    exit 0 ;;
  ''|--check) ;;
  *) frontend_fail '未知参数；请使用 --help。' ;;
esac
[[ $# -le 1 ]] || frontend_fail '参数过多；请使用 --help。'
frontend_check_build_dependencies
if [[ "${1:-}" == '--check' ]]; then
  printf '构建依赖检查通过；架构：%s，模板：%s\n' "$FRONTEND_ARCH" "$FRONTEND_TEMPLATE"
  exit 0
fi

framework="$FRONTEND_BUILD/Frameworks/Sparkle.framework"
mkdir -p "$FRONTEND_BUILD/Frameworks" "$FRONTEND_BUILD/swift-cache"
rm -rf -- "$framework"
/usr/bin/ditto --noqtn "$FRONTEND_RUNTIME/Sparkle.framework" "$framework"
# These headers are used only for compilation; the packaged app retains its
# complete runtime framework from the application template.
rm -rf -- "$framework/Headers" "$framework/Modules"
/usr/bin/ditto --noqtn "$FRONTEND_SPARKLE_SDK/Headers/" "$framework/Headers"
/usr/bin/ditto --noqtn "$FRONTEND_SPARKLE_SDK/Modules/" "$framework/Modules"

sources=("$FRONTEND_ROOT"/frontend/sources/*.swift)
temporary_binary="$FRONTEND_BUILD/Squirrel.new"
trap 'rm -f -- "$temporary_binary"' EXIT
"$FRONTEND_SWIFTC" -O -enable-bare-slash-regex -swift-version 5 \
  -module-name Squirrel -target "$FRONTEND_ARCH-apple-macosx13.0" \
  -sdk "$FRONTEND_SDK" -module-cache-path "$FRONTEND_BUILD/swift-cache" \
  -I "$FRONTEND_ROOT/native/include" -F "$FRONTEND_BUILD/Frameworks" \
  -import-objc-header "$FRONTEND_ROOT/frontend/sources/Squirrel-Bridging-Header.h" \
  "${sources[@]}" -framework AppKit -framework InputMethodKit -framework Carbon \
  -framework ApplicationServices -framework IOKit -framework Sparkle "$FRONTEND_RUNTIME/librime.1.dylib" \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -o "$temporary_binary"
mv -f -- "$temporary_binary" "$FRONTEND_BUILD/Squirrel"
trap - EXIT
printf '已构建：%s\n' "$FRONTEND_BUILD/Squirrel"
