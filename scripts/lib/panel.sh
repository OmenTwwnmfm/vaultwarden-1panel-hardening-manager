# shellcheck shell=bash
# shellcheck disable=SC2034
# 1Panel 面板（通过 1pctl）；由 vh-common.sh 加载，不要单独执行

# ---------- 1Panel ----------
panel_installed() { command -v 1pctl >/dev/null 2>&1; }
panel_version() {
  local out
  out=$(timeout 20 1pctl version 2>/dev/null) || true
  grep -m1 -Eo 'v[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*' <<<"$out"
}
panel_units() { # v2 为 1panel-core / 1panel-agent，v1 为 1panel
  local u
  for u in 1panel-core 1panel-agent 1panel; do
    systemctl cat "$u.service" >/dev/null 2>&1 && echo "$u"
  done
  return 0
}
panel_active() {
  local u
  u=$(panel_units | head -n1)
  [[ -n $u ]] && systemctl is-active --quiet "$u"
}
panel_url() {
  local out
  out=$(timeout 20 1pctl user-info 2>/dev/null) || true
  grep -m1 -Eo 'https?://[^[:space:]]+' <<<"$out"
}
# 当前 1pctl reset 帮助中列出的子命令（空格分隔）。1pctl reset 不带参数时由 1panel 打印帮助
reset_available() {
  local out
  out=$(timeout 20 1pctl reset 2>&1) || true
  sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | awk '/^[[:space:]]+[a-z]+[[:space:]]/ { printf "%s ", $1 }'
}
panel_port_of() { sed -nE 's#^https?://[^/]*:([0-9]+)(/.*)?$#\1#p' <<<"$1"; }
panel_entrance_of() { sed -nE 's#^https?://[^/]*:[0-9]+/?([^[:space:]]*)$#\1#p' <<<"$1"; }
panel_wait_port() { # 最多等待 40 秒，直到端口在监听
  local i
  for ((i = 0; i < 40; i++)); do
    [[ -n $(ss -ltnH "sport = :$1" 2>/dev/null) ]] && return 0
    sleep 1
  done
  return 1
}
panel_set_port() { # 1pctl update port 从标准输入读取新端口，修改后自动重启面板
  printf '%s\n' "$1" | timeout 90 1pctl update port || return 1
  panel_wait_port "$1"
}
panel_restart_core() {
  local u
  u=$(panel_units | head -n1)
  [[ -n $u ]] || return 1
  systemctl restart "$u"
}
panel_listen() { # ipv4 | ipv6
  [[ $1 == ipv4 || $1 == ipv6 ]] || return 1
  timeout 60 1pctl listen-ip "$1" && panel_restart_core
}
