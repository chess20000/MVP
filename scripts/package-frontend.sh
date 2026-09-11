#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/frontend-common.sh"

case "${1:-}" in
  --help|-h)
    cat <<HELP
用法：scripts/package-frontend.sh [--check|--skip-build]
默认先构建，再生成 dist/Squirrel-Ghost-$FRONTEND_VERSION.pkg；不会安装。
--check       仅检查构建和打包依赖，不写入文件。
--skip-build  使用已有 .build/Squirrel，适用于刚刚完成构建的情况。
应用使用本地临时签名，pkg 未签名，供本机安装；不会请求开发者证书或联网。
HELP
    exit 0 ;;
  ''|--check|--skip-build) ;;
  *) frontend_fail '未知参数；请使用 --help。' ;;
esac
[[ $# -le 1 ]] || frontend_fail '参数过多；请使用 --help。'
frontend_require_macos
[[ -x /usr/bin/pkgbuild && -x /usr/bin/codesign ]] || frontend_fail '缺少 macOS pkgbuild 或 codesign。'
/usr/bin/plutil -lint "$FRONTEND_SCRIPT_DIR/frontend-components.plist" >/dev/null
if [[ "${1:-}" == '--check' ]]; then
  "$FRONTEND_SCRIPT_DIR/build-frontend.sh" --check
  printf '打包依赖检查通过；版本：%s\n' "$FRONTEND_VERSION"
  exit 0
fi
if [[ "${1:-}" != '--skip-build' ]]; then "$FRONTEND_SCRIPT_DIR/build-frontend.sh"; fi
frontend_resolve_template
[[ -x "$FRONTEND_BUILD/Squirrel" ]] || frontend_fail '缺少 .build/Squirrel；请先运行 build-frontend.sh。'

stage="$FRONTEND_BUILD/package-root"
mkdir -p "$FRONTEND_BUILD" "$FRONTEND_DIST"
rm -rf -- "$stage"
mkdir -p "$stage"
/usr/bin/ditto --noqtn "$FRONTEND_TEMPLATE" "$stage/Squirrel.app"
cp "$FRONTEND_BUILD/Squirrel" "$stage/Squirrel.app/Contents/MacOS/Squirrel"
plist="$stage/Squirrel.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $FRONTEND_VERSION" "$plist"
if /usr/libexec/PlistBuddy -c 'Print :GhostCompletionVersion' "$plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :GhostCompletionVersion $FRONTEND_GHOST_VERSION" "$plist"
else
  /usr/libexec/PlistBuddy -c "Add :GhostCompletionVersion string $FRONTEND_GHOST_VERSION" "$plist"
fi
/usr/bin/codesign --force --deep --sign - --timestamp=none "$stage/Squirrel.app"
/usr/bin/codesign --verify --deep --strict "$stage/Squirrel.app"
/usr/bin/pkgbuild --root "$stage" \
  --component-plist "$FRONTEND_SCRIPT_DIR/frontend-components.plist" \
  --identifier local.rime.ghost.frontend --version "$FRONTEND_VERSION" \
  --install-location '/Library/Input Methods' "$FRONTEND_PACKAGE"
(cd "$FRONTEND_DIST" && /usr/bin/shasum -a 256 "$(basename -- "$FRONTEND_PACKAGE")") > "$FRONTEND_PACKAGE.sha256"
# Staging copies share the input-method bundle ID. Unregister them so Settings
# does not list a new 鼠须管 for every package build.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$lsregister" ]]; then "$lsregister" -u "$stage/Squirrel.app" >/dev/null 2>&1 || true; fi
printf '已打包：%s\n如需安装，请手动运行 scripts/install-frontend.sh。\n' "$FRONTEND_PACKAGE"
