#!/usr/bin/env bash
# Fail2Ban：安装、SSH 防护配置（写入 jail.d/vhm-sshd.local，不改系统自带文件）、状态、封禁列表、解封
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

valid_time() { [[ $1 =~ ^[0-9]+[smhdw]?$ || $1 == -1 ]]; }
valid_ips() { # 空格分隔的 IP / CIDR
  local x
  for x in $1; do
    [[ $x =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ || $x =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] || return 1
  done
}

jail_get() { sed -nE "s/^$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$F2B_JAIL" 2>/dev/null | tail -n1; }

my_ip() { local a; read -r -a a <<<"${SSH_CONNECTION:-}"; echo "${a[0]:-}"; }

log_backend() { # Debian 12+/Ubuntu 24.04 默认没有 /var/log/auth.log
  if [[ -s /var/log/auth.log ]]; then echo auto; else echo systemd; fi
}

setup() {
  title "Fail2Ban SSH 防护"
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || { log_err "未找到 apt-get，请手动安装 fail2ban"; return 1; }
    confirm_yes "未安装 Fail2Ban，现在安装？" || return 0
    apt_install fail2ban || return 1
    [[ $(log_backend) == systemd ]] && ! python3 -c 'import systemd' 2>/dev/null &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y python3-systemd >/dev/null 2>&1
  fi
  local port maxretry findtime bantime ignore me
  port=$(sshd_get port | sort -un | paste -sd,)
  me=$(my_ip)
  echo "SSH 端口（自动识别）：${port:-22}"
  [[ -d /opt/1panel ]] && log_warn "如果 1Panel「Fail2ban」页面也启用了 sshd 防护，两边会重复封禁，建议只保留 vhm 这一份"
  maxretry=$(read_default "最多允许失败几次" "$(jail_get maxretry || true)")
  maxretry=${maxretry:-5}
  findtime=$(read_default "统计时间窗口（如 10m、1h）" "$(jail_get findtime || true)")
  findtime=${findtime:-10m}
  bantime=$(read_default "封禁时长（如 1h、1d；-1 为永久）" "$(jail_get bantime || true)")
  bantime=${bantime:-1d}
  ignore=$(jail_get ignoreip || true)
  ignore=${ignore#127.0.0.1/8 ::1}
  ignore=${ignore# }
  [[ -z $ignore && -n $me ]] && ignore=$me
  ignore=$(read_default "白名单 IP（空格分隔，可留空；当前连接 IP：${me:-未知}）" "$ignore")
  [[ $maxretry =~ ^[1-9][0-9]?$ ]] || { log_err "失败次数需为 1-99"; return 1; }
  valid_time "$findtime" && valid_time "$bantime" || { log_err "时间格式无效"; return 1; }
  valid_ips "$ignore" || { log_err "白名单格式无效"; return 1; }
  echo
  echo "将写入 $F2B_JAIL：端口 ${port:-22}，${findtime} 内失败 ${maxretry} 次封禁 ${bantime}，白名单 ${ignore:-无}"
  confirm_yes "确认保存并重启 Fail2Ban？" || return 0
  change_begin "Fail2Ban SSH 防护：失败 $maxretry 次封禁 $bantime" fail2ban
  change_track "$F2B_JAIL" || return 1
  install -d -m 755 "$(dirname "$F2B_JAIL")"
  cat >"$F2B_JAIL" <<EOF
# 由 vhm 管理，可在 vhm [24] 中回滚
[sshd]
enabled = true
port = ${port:-22}
backend = $(log_backend)
maxretry = $maxretry
findtime = $findtime
bantime = $bantime
ignoreip = 127.0.0.1/8 ::1${ignore:+ $ignore}
EOF
  chmod 644 "$F2B_JAIL"
  local out
  if ! out=$(fail2ban-client -t 2>&1); then
    log_err "Fail2Ban 配置检查未通过，已恢复：$(tail -n 3 <<<"$out")"
    change_rollback "$CHG_ID"
    return 1
  fi
  systemctl enable fail2ban >/dev/null 2>&1 || true
  if ! systemctl restart fail2ban || ! sleep 2 || ! fail2ban-client status sshd >/dev/null 2>&1; then
    log_err "Fail2Ban 启动失败，已恢复原配置。查看：journalctl -u fail2ban -n 30"
    change_rollback "$CHG_ID"
    return 1
  fi
  change_status applied
  log_ok "Fail2Ban SSH 防护已生效"
}

manage() {
  title "Fail2Ban 状态"
  command -v fail2ban-client >/dev/null 2>&1 || { log_warn "未安装 Fail2Ban，请先使用 [15]"; return 0; }
  systemctl is-active --quiet fail2ban || { log_warn "Fail2Ban 未运行：systemctl status fail2ban"; return 0; }
  fail2ban-client status 2>/dev/null | sed 's/^/  /'
  echo
  if ! fail2ban-client status sshd >/dev/null 2>&1; then
    log_warn "没有 sshd 防护，请使用 [15] 配置"
    return 0
  fi
  fail2ban-client status sshd 2>/dev/null | sed 's/^/  /'
  [[ -f $F2B_JAIL ]] && echo "  配置：$F2B_JAIL（失败 $(jail_get maxretry) 次 / $(jail_get findtime) 内，封禁 $(jail_get bantime)）"
  echo
  local ip
  read -r -p "输入要解封的 IP（回车返回）: " ip || return 0
  [[ -n $ip ]] || return 0
  valid_ips "$ip" || { log_err "IP 格式无效"; return 1; }
  if fail2ban-client set sshd unbanip "$ip" >/dev/null 2>&1; then
    log_ok "已解封 $ip"
  else
    log_warn "$ip 不在 sshd 封禁列表中"
  fi
}

case ${1:-manage} in
  setup) need_root; with_lock setup ;;
  manage) need_root; manage ;;
  *) die "未知参数：$1" ;;
esac
