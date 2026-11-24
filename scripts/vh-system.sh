#!/usr/bin/env bash
# 系统加固：自动安全更新（unattended-upgrades）、内核网络参数（/etc/sysctl.d/90-vhm-hardening.conf）
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

# ---------- 自动安全更新 ----------
au_enabled() {
  [[ $(apt-config dump 2>/dev/null | sed -nE 's/^APT::Periodic::Unattended-Upgrade "([0-9]+)";/\1/p') =~ ^[1-9] ]] &&
    systemctl is-enabled --quiet unattended-upgrades 2>/dev/null
}

au_status() {
  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    echo "当前：未安装 unattended-upgrades"
  elif au_enabled; then
    echo "当前：已启用（每天自动安装安全更新）"
    local last
    last=$(ls -t /var/log/unattended-upgrades/unattended-upgrades.log* 2>/dev/null | head -n1)
    [[ -n $last ]] && echo "最近日志：$last（$(stat -c %y "$last" | cut -d. -f1)）"
  else
    echo "当前：已安装但未启用"
  fi
  [[ -f /var/run/reboot-required ]] && log_warn "有已安装的更新需要重启才能生效"
  return 0
}

au_write() { # au_write 0|1
  change_track "$AUTO_UPGRADES" || return 1
  install -d -m 755 "$(dirname "$AUTO_UPGRADES")"
  printf 'APT::Periodic::Update-Package-Lists "%s";\nAPT::Periodic::Unattended-Upgrade "%s";\n' "$1" "$1" >"$AUTO_UPGRADES"
  chmod 644 "$AUTO_UPGRADES"
}

auto_updates() {
  title "自动安全更新"
  command -v apt-get >/dev/null 2>&1 || { log_err "仅支持 Debian / Ubuntu（apt）"; return 1; }
  au_status
  echo
  echo "只自动安装系统的安全更新，不会升级 Docker 容器和 1Panel 应用；不会自动重启。"
  echo "  [1] 启用   [2] 关闭   [0] 返回"
  local c
  read -r -p "请选择：" c || return 0
  case $c in
    1)
      confirm_yes "安装并启用 unattended-upgrades？" || return 0
      if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades || { log_err "安装失败"; return 1; }
      fi
      change_begin "启用自动安全更新"
      au_write 1 || { change_rollback "$CHG_ID"; return 1; }
      systemctl enable --now unattended-upgrades >/dev/null 2>&1 || log_warn "无法启用 unattended-upgrades 服务"
      if unattended-upgrade --dry-run >/dev/null 2>&1; then
        change_status applied
        log_ok "已启用自动安全更新"
      else
        log_warn "已启用，但试运行失败，请查看：unattended-upgrade --dry-run -d"
        change_status applied
      fi
      ;;
    2)
      confirm_yes "关闭自动安全更新？" || return 0
      change_begin "关闭自动安全更新"
      au_write 0 || { change_rollback "$CHG_ID"; return 1; }
      change_status applied
      log_ok "已关闭（软件包保留）"
      ;;
  esac
}

# ---------- 内核网络参数 ----------
# rp_filter 用 2（宽松模式）：严格模式在 Docker 多网卡环境下可能丢包；不改 ip_forward（Docker 需要）
SYSCTL_PARAMS=(
  net.ipv4.tcp_syncookies=1
  net.ipv4.conf.all.rp_filter=2
  net.ipv4.conf.default.rp_filter=2
  net.ipv4.conf.all.accept_redirects=0
  net.ipv4.conf.default.accept_redirects=0
  net.ipv6.conf.all.accept_redirects=0
  net.ipv6.conf.default.accept_redirects=0
  net.ipv4.conf.all.secure_redirects=0
  net.ipv4.conf.all.send_redirects=0
  net.ipv4.conf.default.send_redirects=0
  net.ipv4.conf.all.accept_source_route=0
  net.ipv4.conf.default.accept_source_route=0
  net.ipv6.conf.all.accept_source_route=0
  net.ipv4.icmp_echo_ignore_broadcasts=1
  net.ipv4.icmp_ignore_bogus_error_responses=1
)

sysctl_menu() {
  title "内核网络参数加固"
  local p k want v diff=0
  printf '  %-44s %-6s %s\n' 参数 当前 建议
  for p in "${SYSCTL_PARAMS[@]}"; do
    k=${p%%=*} want=${p#*=}
    v=$(sysctl -n "$k" 2>/dev/null) || v=不支持
    [[ $v == "$want" || $v == 不支持 ]] || diff=1
    printf '  %-44s %-6s %s\n' "$k" "$v" "$want"
  done
  echo
  [[ -f $SYSCTL_FILE ]] && echo "vhm 配置文件：$SYSCTL_FILE"
  echo "作用：开启 SYN cookies 抵御 SYN 洪泛；拒绝 ICMP 重定向与源路由；开启反向路径过滤（宽松模式）。不影响 Docker 端口转发。"
  if ((diff == 0)); then
    log_ok "所有参数均已是建议值"
    return 0
  fi
  confirm_yes "写入 $SYSCTL_FILE 并立即生效？" || return 0
  change_begin "内核网络参数加固" sysctl
  change_track "$SYSCTL_FILE" || { change_rollback "$CHG_ID"; return 1; }
  : >"$CHG_DIR/sysctl.prev"
  {
    echo "# 由 vhm 管理，可在 vhm [24] 中回滚"
    for p in "${SYSCTL_PARAMS[@]}"; do
      k=${p%%=*}
      v=$(sysctl -n "$k" 2>/dev/null) || continue
      printf '%s=%s\n' "$k" "$v" >>"$CHG_DIR/sysctl.prev"
      echo "$p"
    done
  } >"$SYSCTL_FILE"
  chmod 644 "$SYSCTL_FILE"
  if ! sysctl -q -p "$SYSCTL_FILE" >/dev/null; then
    log_err "参数生效失败，正在恢复"
    change_rollback "$CHG_ID"
    return 1
  fi
  change_status applied
  log_ok "内核网络参数已加固，重启后保持"
}

case ${1:-} in
  auto-updates) need_root; with_lock auto_updates ;;
  sysctl) need_root; with_lock sysctl_menu ;;
  *) die "用法：vh-system.sh auto-updates|sysctl" ;;
esac
