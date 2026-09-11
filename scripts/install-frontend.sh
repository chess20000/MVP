#!/bin/bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/frontend-common.sh"

check_only=false
if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
  cat <<HELP
用法：scripts/install-frontend.sh [--check] [安装包路径]
默认安装 dist/Squirrel-Ghost-$FRONTEND_VERSION.pkg；必须由用户手动运行。
--check  仅检查安装包和当前安装环境，不安装、不备份、不重载输入法。
实际安装先备份当前应用及前端资料，再通过系统安装器请求管理员授权，
安装到 /Library/Input Methods，最后退出旧实例并注册、启动和选择鼠须管。
请以当前登录用户运行本脚本，不要使用 sudo。
HELP
  exit 0
fi
if [[ "${1:-}" == '--check' ]]; then check_only=true; shift; fi
[[ $# -le 1 ]] || frontend_fail '参数过多；请使用 --help。'
[[ "${1:-}" != --* ]] || frontend_fail '未知参数；请使用 --help。'
package="${1:-$FRONTEND_PACKAGE}"
frontend_require_macos
[[ "$EUID" -ne 0 ]] || frontend_fail '请以当前登录用户运行，不要使用 sudo；系统安装器会单独请求管理员授权。'
[[ -f "$package" ]] || frontend_fail "安装包不存在：$package；请先运行 package-frontend.sh。"
package="$(CDPATH= cd -- "$(dirname -- "$package")" && pwd -P)/$(basename -- "$package")"
[[ "$package" == *.pkg ]] || frontend_fail '安装包必须是 .pkg 文件。'
[[ -x /usr/sbin/installer && -x /usr/bin/osascript ]] || frontend_fail '缺少系统安装工具。'
/usr/sbin/pkgutil --payload-files "$package" >/dev/null \
  || frontend_fail '无法读取安装包内容；请重新打包。'
if "$check_only"; then
  printf '安装检查通过：%s\n当前应用：%s\n没有执行安装或重载。\n' "$package" "$FRONTEND_APP"
  exit 0
fi

umask 077
base="$HOME/Library/Rime/ghost"
backup="$base/backups/frontend-$FRONTEND_VERSION-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$backup"
if [[ -d "$FRONTEND_APP" ]]; then /usr/bin/ditto --noqtn "$FRONTEND_APP" "$backup/Squirrel.app"; fi
for name in limits.json 使用说明.md Squirrel-Ghost.pkg; do
  if [[ -f "$base/$name" ]]; then cp "$base/$name" "$backup/$name"; fi
done
if [[ -d "$base/sources" ]]; then /usr/bin/ditto --noqtn "$base/sources" "$backup/sources"; fi
printf '已备份当前前端：%s\n' "$backup"

# Elevated installer cannot read some user folders (Chinese paths, TCC).
staged="/tmp/Squirrel-Ghost-${FRONTEND_VERSION}-$$.pkg"
/bin/cp "$package" "$staged"
trap 'rm -f -- "$staged"' EXIT
# The package has no postinstall hook: reload only in this logged-in user's session.
/usr/bin/osascript "$FRONTEND_SCRIPT_DIR/install-package.applescript" "$staged"
binary="$FRONTEND_APP/Contents/MacOS/Squirrel"
[[ -x "$binary" ]] || frontend_fail "安装后找不到鼠须管程序；备份位于 $backup"
"$binary" --quit
for ((attempt = 0; attempt < 50; attempt++)); do
  if ! /usr/bin/pgrep -u "$UID" -x Squirrel >/dev/null; then break; fi
  /bin/sleep 0.1
done
if /usr/bin/pgrep -u "$UID" -x Squirrel >/dev/null; then
  frontend_fail "鼠须管尚未退出，停止重载以避免重复实例。应用已安装；备份位于 $backup"
fi
registration="$("$binary" --register-ghost)"
printf '%s\n' "$registration"
[[ "${registration##*$'\n'}" == 'Register status: 0' ]] \
  || frontend_fail "注册输入源失败；未继续启动。备份位于 $backup"
"$binary" --enable-input-source im.rime.inputmethod.Squirrel.Hans
/usr/bin/open "$FRONTEND_APP"
"$binary" --select-input-source im.rime.inputmethod.Squirrel.Hans

# Keep a copy of the installed frontend for later inspection and rollback.
if [[ ! "$package" -ef "$base/Squirrel-Ghost.pkg" ]]; then cp "$package" "$base/Squirrel-Ghost.pkg"; fi
if [[ -d "$FRONTEND_ROOT/frontend/sources" ]]; then
  /usr/bin/ditto --noqtn "$FRONTEND_ROOT/frontend/sources" "$base/sources"
fi
/usr/bin/shasum -a 256 "$binary" > "$base/frontend-installed.sha256"
printf '鼠须管前端安装完成。备份：%s\n' "$backup"
