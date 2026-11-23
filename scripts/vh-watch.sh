#!/usr/bin/env bash
# 定时巡检：systemd timer 安装/状态/暂停/恢复；run 时仅在出现新 fail 时通知
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"
LIB=/usr/local/lib/vaultwarden-hardening
UNIT=vaultwarden-hardening-watch

# 通知：URL（可能含 token）经标准输入交给 curl，不出现在进程命令行；失败不改变任务结果
notify() {
  local msg="$1" t c n w
  t=$(conf_get NOTIFY_TELEGRAM_TOKEN || true)
  c=$(conf_get NOTIFY_TELEGRAM_CHAT || true)
  n=$(conf_get NOTIFY_NTFY_URL || true)
  w=$(conf_get NOTIFY_WEBHOOK_URL || true)
  if [[ -n $t && -n $c ]]; then
    curl_url "https://api.telegram.org/bot$t/sendMessage" -d chat_id="$c" --data-urlencode text="$msg" >/dev/null 2>&1 ||
      log_warn "Telegram 通知发送失败"
  fi
  if [[ -n $n ]]; then
    curl_url "$n" -d "$msg" >/dev/null 2>&1 || log_warn "ntfy 通知发送失败"
  fi
  if [[ -n $w ]]; then
    curl_url "$w" -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys;print(json.dumps({"text":sys.argv[1]}))' "$msg")" >/dev/null 2>&1 ||
      log_warn "Webhook 通知发送失败"
  fi
  return 0
}

sync_scripts() {
  install -d -m 755 "$LIB" "$LIB/scripts"
  cp -a "$VH_DIR/." "$LIB/scripts/"
  install -m 644 "$VH_DIR/../VERSION" "$LIB/VERSION"
  log_ok "后台脚本已同步到 $LIB"
}

install_timer() {
  need_root
  sync_scripts
  [[ "${1:-}" == --sync-only ]] && return 0
  local cal
  cal=$(conf_get WATCH_ONCALENDAR || true)
  cal=${cal:-daily}
  cat >"/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Vaultwarden hardening watch (vhm)
After=docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash $LIB/scripts/vh-watch.sh run
SuccessExitStatus=75
EOF
  cat >"/etc/systemd/system/$UNIT.timer" <<EOF
[Unit]
Description=Vaultwarden hardening watch timer
[Timer]
OnCalendar=$cal
Persistent=true
RandomizedDelaySec=10m
[Install]
WantedBy=timers.target
EOF
  if systemctl daemon-reload && systemctl enable --now "$UNIT.timer"; then
    log_ok "定时巡检已安装（$cal）"
  else
    die "systemd 定时器启用失败"
  fi
}

run_watch() {
  local R="$VH_STATE/reports" prev="" new added
  [[ -e "$R/latest.json" ]] && prev=$(readlink -f "$R/latest.json")
  bash "$VH_DIR/vh-audit.sh" >/dev/null || return $?
  new=$(readlink -f "$R/latest.json")
  added=$(python3 "$VH_DIR/vh_rules.py" diff "${prev:-/dev/null}" "$new" | paste -sd, -)
  if [[ -n "$added" ]]; then
    notify "[vhm] $(hostname) 新增失败项：$added"
    log_warn "新增失败项：$added"
  fi
}

case "${1:-status}" in
  install) shift; install_timer "$@" ;;
  status) systemctl list-timers "$UNIT.timer" --no-pager 2>/dev/null || log_warn "未安装" ;;
  pause) need_root; systemctl disable --now "$UNIT.timer" && log_ok "已暂停" ;;
  resume) need_root; systemctl enable --now "$UNIT.timer" && log_ok "已恢复" ;;
  notify-test) notify "[vhm] $(hostname) 通知测试"; log_ok "已发送（失败不报错，请查看接收端）" ;;
  run) with_lock run_watch ;;
  *) die "用法：vh-watch.sh install|status|pause|resume|notify-test|run" ;;
esac
