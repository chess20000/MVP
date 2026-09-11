#!/bin/bash
# 投机输入法：给中国大陆小白用的一键安装。
# 请复制下面这一行到「终端」里运行（不要用 sudo）：
# curl -fsSL https://ghfast.top/https://github.com/chess20000/MVP/releases/latest/download/install.sh | bash
set -euo pipefail

REPO="${GHOST_REPO:-chess20000/MVP}"
VERSION="${GHOST_VERSION:-1.1.2.11}"
PKG_NAME="Squirrel-Ghost-${VERSION}.pkg"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export HF_ENDPOINT
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
export TOKENIZERS_PARALLELISM=false
export PYTHONDONTWRITEBYTECODE=1

MIRRORS=(
  "${GHOST_GITHUB_MIRROR:-https://ghfast.top/}"
  "https://gh-proxy.com/"
  "https://mirror.ghproxy.com/"
  "https://ghproxy.net/"
  "https://github.moeyy.xyz/"
)

PYTHON_PKG_VERSION="3.12.10"
PYTHON_PKG_NAME="python-${PYTHON_PKG_VERSION}-macos11.pkg"
PYTHON_PKG_MIRRORS=(
  "https://mirrors.huaweicloud.com/python/${PYTHON_PKG_VERSION}/${PYTHON_PKG_NAME}"
  "https://cdn.npmmirror.com/binaries/python/${PYTHON_PKG_VERSION}/${PYTHON_PKG_NAME}"
)

fail() {
  printf '\n安装没有完成：%s\n' "$*" >&2
  printf '请把终端里从「安装没有完成」往上的几行发给作者。不要用 sudo 重试。\n' >&2
  exit 1
}

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

[[ "$(uname -s)" == Darwin ]] || fail "这是 Mac 专用输入法，目前只支持苹果电脑。"
[[ "$(uname -m)" == arm64 ]] || fail "需要苹果芯片的 Mac（M1 / M2 / M3 / M4）。Intel 的 Mac 装不了续写。"
[[ "$(id -u)" -ne 0 ]] || fail "请不要用 sudo。弹出密码窗口时，输入开机密码即可。"

export PATH="/Library/Frameworks/Python.framework/Versions/3.14/bin:/Library/Frameworks/Python.framework/Versions/3.13/bin:/Library/Frameworks/Python.framework/Versions/3.12/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

ROOT=""
_src="${BASH_SOURCE[0]:-}"
if [[ -n "$_src" && -f "$_src" ]]; then
  _dir="$(CDPATH= cd -- "$(dirname -- "$_src")" && pwd -P 2>/dev/null || true)"
  if [[ -n "$_dir" && -f "$_dir/backend/install-service.py" ]]; then
    ROOT="$_dir"
  fi
fi

WORKDIR="/tmp/touji-ime-install-$$"
mkdir -m 700 "$WORKDIR"
trap 'rm -rf -- "$WORKDIR"' EXIT

say "开始安装投机输入法。"
say "过程中可能会弹出一次或两次开机密码窗口；输入时屏幕上不显示圆点，输完按回车。"
say "续写模型大约 1GB，视网速需要几分钟到十几分钟，请不要关这个窗口。"

pick_github_mirror() {
  local mirror sample
  sample="https://github.com/${REPO}/releases/latest"
  if [[ -n "${GHOST_GITHUB_MIRROR:-}" ]]; then
    if curl -fsSL --connect-timeout 8 --max-time 20 "${GHOST_GITHUB_MIRROR}${sample}" >/dev/null; then
      printf '%s\n' "${GHOST_GITHUB_MIRROR%/}/"
      return 0
    fi
  fi
  for mirror in "${MIRRORS[@]}"; do
    [[ -n "$mirror" ]] || continue
    mirror="${mirror%/}/"
    if curl -fsSL --connect-timeout 6 --max-time 15 "${mirror}${sample}" >/dev/null 2>&1; then
      printf '%s\n' "$mirror"
      return 0
    fi
  done
  return 1
}

download() {
  local url="$1" dest="$2"
  local mirror="$3"
  curl -fL --connect-timeout 8 --retry 3 --retry-delay 2 --max-time 600 \
    -o "$dest" "${mirror}${url}"
}

step "正在连接国内 GitHub 镜像…"
GITHUB_MIRROR="$(pick_github_mirror)" \
  || fail "连不上 GitHub 镜像。请换一个 Wi-Fi / 手机热点后再试。也可先设置：export GHOST_GITHUB_MIRROR=https://ghfast.top/"
say "使用镜像：${GITHUB_MIRROR}"

PKG="$WORKDIR/$PKG_NAME"
if [[ -n "$ROOT" && -f "$ROOT/dist/$PKG_NAME" ]]; then
  step "使用本机已有的输入法安装包。"
  cp "$ROOT/dist/$PKG_NAME" "$PKG"
else
  step "正在下载输入法（约 50MB）…"
  download "https://github.com/${REPO}/releases/download/${VERSION}/${PKG_NAME}" "$PKG" "$GITHUB_MIRROR" \
    || download "https://github.com/${REPO}/releases/latest/download/${PKG_NAME}" "$PKG" "$GITHUB_MIRROR" \
    || fail "输入法安装包下载失败。请换一个网络后重试。"
fi
/usr/sbin/pkgutil --payload-files "$PKG" >/dev/null 2>&1 \
  || fail "下载到的安装包打不开。请稍后重试。"

SUM="$WORKDIR/$PKG_NAME.sha256"
if download "https://github.com/${REPO}/releases/download/${VERSION}/${PKG_NAME}.sha256" "$SUM" "$GITHUB_MIRROR" 2>/dev/null \
  || download "https://github.com/${REPO}/releases/latest/download/${PKG_NAME}.sha256" "$SUM" "$GITHUB_MIRROR" 2>/dev/null; then
  expected="$(awk '{print $1; exit}' "$SUM")"
  actual="$(/usr/bin/shasum -a 256 "$PKG" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || fail "安装包校验失败，请重新运行安装。"
fi

if [[ -n "$ROOT" ]]; then
  SOURCE="$ROOT"
else
  step "正在下载安装程序…"
  ARCHIVE="$WORKDIR/src.tar.gz"
  download "https://github.com/${REPO}/archive/refs/tags/${VERSION}.tar.gz" "$ARCHIVE" "$GITHUB_MIRROR" \
    || download "https://github.com/${REPO}/archive/refs/heads/master.tar.gz" "$ARCHIVE" "$GITHUB_MIRROR" \
    || fail "安装程序下载失败。"
  mkdir -p "$WORKDIR/src"
  tar -xzf "$ARCHIVE" -C "$WORKDIR/src"
  SOURCE="$(find "$WORKDIR/src" -mindepth 1 -maxdepth 1 -type d | /usr/bin/head -n 1)"
  [[ -n "$SOURCE" && -f "$SOURCE/backend/install-service.py" ]] || fail "解压后的安装程序不完整。"
fi

find_python() {
  local candidate
  for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1 \
      && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

PYTHON_BIN="$(find_python || true)"
if [[ -z "${PYTHON_BIN}" ]]; then
  step "本机还没有可用的 Python，正在从国内镜像下载（只需这一次）…"
  PYPKG="$WORKDIR/$PYTHON_PKG_NAME"
  py_ok=0
  for url in "${PYTHON_PKG_MIRRORS[@]}"; do
    if curl -fL --connect-timeout 8 --retry 2 --max-time 300 -o "$PYPKG" "$url"; then
      py_ok=1
      break
    fi
  done
  [[ "$py_ok" -eq 1 ]] || fail "Python 下载失败。请检查网络后重试。"
  step "请在弹出的窗口里输入开机密码，用于安装运行环境。"
  /usr/bin/osascript "$SOURCE/scripts/install-package.applescript" "$PYPKG" \
    || fail "运行环境没有装上。如果点了「取消」，请重新运行安装。"
  hash -r
  PYTHON_BIN="$(find_python || true)"
  [[ -n "${PYTHON_BIN}" ]] || fail "运行环境装完后仍然找不到 Python。"
fi
say "运行环境：$PYTHON_BIN"

if [[ -x "$HOME/Library/Rime/ghost/control.sh" ]]; then
  "$HOME/Library/Rime/ghost/control.sh" off >/dev/null 2>&1 || true
fi

step "请在弹出的窗口里输入开机密码，用于安装输入法。"
bash "$SOURCE/scripts/install-frontend.sh" "$PKG" \
  || fail "输入法没有装上。如果点了「取消」，请重新运行安装。"

step "正在准备续写功能（下载模型，大约 1GB，请稍等）…"
export PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
export PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-pypi.tuna.tsinghua.edu.cn}"
PYTHON_BIN="$PYTHON_BIN" bash "$SOURCE/backend/setup.sh" \
  || fail "续写模型下载或依赖安装失败。请换一个网络后重新运行；已装上的输入法可以继续打字。"
"$PYTHON_BIN" "$SOURCE/backend/install-service.py" install \
  || fail "续写服务没有登记成功。"

step "正在启动续写…"
if ! "$HOME/Library/Rime/ghost/control.sh" on; then
  say "模型还在加载，继续等一会儿…"
  started=0
  for ((i = 0; i < 30; i++)); do
    if /usr/bin/curl --silent --fail --max-time 1 http://127.0.0.1:18081/health >/dev/null 2>&1; then
      started=1
      break
    fi
    sleep 2
  done
  if [[ "$started" -eq 0 ]]; then
    "$HOME/Library/Rime/ghost/control.sh" on \
      || say "输入法已经能打字。续写稍后再自动可用；若一直没有灰色续写，请重新打开终端运行：\"\$HOME/Library/Rime/ghost/control.sh\" on"
  fi
fi

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true

cat <<'EOF'

安装完成。

请再做两件小事（否则 Tab 续写可能没反应）：

1. 菜单栏输入法图标里选「鼠须管」。
2. 在刚打开的系统设置里：隐私与安全性 → 辅助功能 → 打开「鼠须管」。
   若有「输入监控」，也打开「鼠须管」。

然后点一下任意输入框，打几个字试试。灰色字是续写，按 Tab 接受。
EOF
