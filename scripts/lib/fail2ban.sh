# shellcheck shell=bash
# shellcheck disable=SC2034
# Fail2Ban 端口同步与 sysctl 恢复；由 vh-common.sh 加载，不要单独执行

f2b_reload() {
  command -v fail2ban-client >/dev/null 2>&1 || return 0
  systemctl restart fail2ban
}

f2b_banned() { fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ { gsub(/[[:space:]]/, "", $2); print $2 }'; }

f2b_sync_ssh_port() {
  command -v fail2ban-client >/dev/null 2>&1 || return 0
  [[ -f $F2B_JAIL ]] || return 0
  f2b_sync_ssh_port_now
}

# Fail2Ban SSH 端口同步的 systemd 单元：.path 监视主配置与整个 drop-in 目录（其他 drop-in 也可能改端口），
# 改动后立即同步；定时器每 5 分钟兜底核对一次（例如软件包升级替换了配置文件）。
# 返回 0 = 有文件被改写，1 = 都无需改写，2 = 写入失败
f2b_sync_units_write() {
  local unit rc changed=1
  for unit in service path timer; do
    rc=0
    case $unit in
      service) unit_write "$F2B_SYNC_SERVICE" "[Unit]
Description=Synchronize Fail2Ban SSH ports with sshd configuration
After=fail2ban.service
[Service]
Type=oneshot
ExecStart=/bin/bash $VH_DIR/vh-fail2ban.sh sync-port
SuccessExitStatus=75" || rc=$? ;;
      path) unit_write "$F2B_SYNC_PATH" "[Unit]
Description=Watch SSH configuration changes for Fail2Ban
[Path]
PathChanged=/etc/ssh/sshd_config
PathModified=/etc/ssh/sshd_config.d
Unit=vhm-ssh-port-sync.service
[Install]
WantedBy=multi-user.target" || rc=$? ;;
      timer) unit_write "$F2B_SYNC_TIMER" "[Unit]
Description=Periodically synchronize Fail2Ban SSH ports
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=multi-user.target" || rc=$? ;;
    esac
    ((rc == 2)) && return 2
    ((rc == 0)) && changed=0
  done
  return $changed
}

f2b_sync_ssh_port_now() {
  local eff ports current out
  eff=$(sshd_eff) || eff=""
  [[ -n $eff ]] || { log_err "sshd -T 未通过，Fail2Ban 端口同步暂缓"; return 1; }
  ports=$(awk '$1 == "port" { print $2 }' <<<"$eff" | sort -un | paste -sd,)
  [[ -n $ports ]] || { log_err "无法从 sshd -T 读取 SSH 端口，Fail2Ban 保持现有配置"; return 1; }
  current=$(sed -nE 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$F2B_JAIL" | tail -n1)
  [[ $current == "$ports" ]] && return 0
  change_begin "Fail2Ban SSH 端口 $current → $ports" fail2ban
  change_track "$F2B_JAIL" || return 1
  if grep -Eq '^[[:space:]]*port[[:space:]]*=' "$F2B_JAIL"; then
    sed -i -E "s/^[[:space:]]*port[[:space:]]*=.*/port = $ports/" "$F2B_JAIL"
  else
    printf 'port = %s\n' "$ports" >>"$F2B_JAIL"
  fi
  if ! out=$(fail2ban-client -t 2>&1) || ! f2b_reload; then
    log_err "Fail2Ban 同步 SSH 端口失败：$(tail -n 3 <<<"$out")"
    change_rollback "$CHG_ID"
    return 1
  fi
  change_status applied
  log_ok "Fail2Ban 已同步 SSH 端口：$ports"
}

sysctl_restore() { # 恢复修改前记录的运行时参数
  local d=$1 k v rc=0
  [[ -f $d/sysctl.prev ]] || return 0
  while IFS='=' read -r k v; do
    [[ -n $k ]] || continue
    sysctl -q -w "$k=$v" >/dev/null || rc=1
  done <"$d/sysctl.prev" || rc=1
  return "$rc"
}
