#!/bin/bash
set -euo pipefail
control_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${RIME_GHOST_BASE:-}" ]]; then
  base="$RIME_GHOST_BASE"
elif [[ -f "$control_dir/mlx/server.py" && -d "$control_dir/mlx-runtime" ]]; then
  base="$control_dir"
else
  base="$HOME/Library/Rime/ghost"
fi
domain="gui/$(id -u)"
selected="mlx"

stop_backend() {
  local backend_name="$1"
  local label="local.rime.ghost.$backend_name"
  launchctl disable "$domain/$label"
  launchctl bootout "$domain" "$HOME/Library/LaunchAgents/$label.plist" 2>/dev/null || true
}

backend_ready() {
  local backend_name="$1"
  local label="local.rime.ghost.$backend_name"
  local job_pid listener_pid health
  job_pid=$(launchctl print "$domain/$label" 2>/dev/null | awk '/^[[:space:]]*pid = / { value=$3 } END { print value }') || return 1
  [[ "$job_pid" =~ ^[0-9]+$ ]] || return 1
  listener_pid=$(/usr/sbin/lsof -nP -a -p "$job_pid" -iTCP:18081 -sTCP:LISTEN -t 2>/dev/null) || return 1
  [[ "$listener_pid" == "$job_pid" ]] || return 1
  health=$(/usr/bin/curl --silent --fail --max-time 1 http://127.0.0.1:18081/health) || return 1
  if [[ "$backend_name" == mlx ]]; then
    [[ "$health" == *'"backend":"mlx"'* ]] || return 1
  fi
}

start_backend() {
  local backend_name="$1"
  local label="local.rime.ghost.$backend_name"
  local agent="$HOME/Library/LaunchAgents/$label.plist"
  [[ -f "$agent" ]] || { echo '这个续写服务尚未安装'; exit 1; }
  [[ -d "$base" ]] || { echo '续写服务目录不存在'; exit 1; }
  # Invalidate old token queues before changing tokenizer/model at the same port.
  touch "$base/disabled"
  /usr/bin/uuidgen > "$base/backend-generation.tmp"
  mv "$base/backend-generation.tmp" "$base/backend-generation"
  sleep 0.5
  launchctl enable "$domain/$label"
  if ! launchctl bootstrap "$domain" "$agent" 2>/dev/null; then
    launchctl kickstart "$domain/$label" || { stop_backend "$backend_name"; return 1; }
  fi
  for attempt in {1..60}; do
    if backend_ready "$backend_name"; then
      printf '%s\n' "$backend_name" > "$base/backend"
      rm -f "$base/disabled"
      echo "幽灵续写已启用：$backend_name"
      return
    fi
    sleep 0.5
  done
  stop_backend "$backend_name"
  echo '模型尚未就绪，幽灵续写保持暂停。普通中文输入不受影响。'
  exit 1
}

case "${1:-status}" in
  off) mkdir -p "$base"; touch "$base/disabled"; stop_backend mlx; echo '幽灵续写已暂停，模型服务已停止。' ;;
  on) start_backend "$selected" ;;
  mlx) start_backend mlx ;;
  status) launchctl print "$domain/local.rime.ghost.$selected" | sed -n '1,25p' ;;
  *) echo '用法: control.sh on|off|status|mlx'; exit 2 ;;
esac
