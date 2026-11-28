# shellcheck shell=bash
# shellcheck disable=SC2034
# 变更记录、回滚与 SSH 防锁死保护；由 vh-common.sh 加载，不要单独执行

# ---------- 变更记录与回滚 ----------
# 目录：$VH_CHANGES/<YYYYmmdd-HHMMSS-PID>/
#   meta（ID/TIME/DESC/HOOKS）、status（pending/applied/confirmed/rolled_back/rollback_failed）
#   files.tsv（序号、修改前是否存在、权限、属主、路径），files/<序号> 为原文件副本
change_begin() { # change_begin 描述 [回滚钩子...]
  change_prune
  CHG_ID="$(date '+%Y%m%d-%H%M%S')-$$"
  # 同一进程同一秒内多次修改（如连续添加密钥）时避免记录目录重名
  while [[ -e "$VH_CHANGES/$CHG_ID" ]]; do
    sleep 1
    CHG_ID="$(date '+%Y%m%d-%H%M%S')-$$"
  done
  CHG_DIR="$VH_CHANGES/$CHG_ID"
  install -d -m 700 "$VH_STATE" "$VH_CHANGES" "$CHG_DIR" "$CHG_DIR/files" || die "无法创建变更记录目录"
  : >"$CHG_DIR/files.tsv" || die "无法初始化变更记录"
  {
    printf 'ID=%s\n' "$CHG_ID"
    printf 'TIME=%s\n' "$(date '+%F %T')"
    printf 'DESC=%s\n' "${1//$'\n'/ }"
    printf 'HOOKS=%s\n' "${*:2}"
  } >"$CHG_DIR/meta" || die "无法保存变更记录"
  change_status pending || die "无法保存变更状态"
}

change_write_status() {
  local dir=$1 status=$2 tmp
  tmp=$(mktemp "$dir/.status.XXXXXX") || return 1
  if printf '%s\n' "$status" >"$tmp" && mv -fT -- "$tmp" "$dir/status"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

change_status() { change_write_status "$CHG_DIR" "$1"; }

change_track() { # 修改文件前调用；同一路径只记录一次
  local p=$1 n
  [[ -n "${CHG_DIR:-}" ]] || { log_err "内部错误：未开始变更记录"; return 1; }
  awk -F'\t' -v p="$p" '$5 == p { f = 1 } END { exit !f }' "$CHG_DIR/files.tsv" && return 0
  n=$(($(wc -l <"$CHG_DIR/files.tsv") + 1))
  if [[ -f "$p" ]]; then
    cp -a -- "$p" "$CHG_DIR/files/$n" || return 1
    printf '%s\t1\t%s\t%s\t%s\n' "$n" "$(stat -c %a "$p")" "$(stat -c %u:%g "$p")" "$p" >>"$CHG_DIR/files.tsv"
  elif [[ -e "$p" ]]; then
    log_err "$p 不是普通文件，拒绝修改"
    return 1
  else
    printf '%s\t0\t-\t-\t%s\n' "$n" "$p" >>"$CHG_DIR/files.tsv"
  fi
}

change_restore_files() { # change_restore_files 记录目录
  local d=$1 n ex mode own p rc=0
  while IFS=$'\t' read -r n ex mode own p; do
    [[ -n $p ]] || continue
    if [[ $ex == 1 ]]; then
      mkdir -p "$(dirname "$p")"
      { cp -a -- "$d/files/$n" "$p.vhm-restore" && mv -f -- "$p.vhm-restore" "$p"; } || { log_err "无法恢复 $p"; rc=1; }
    else
      rm -f -- "$p" || rc=1
    fi
  done <"$d/files.tsv" || return 1
  return $rc
}

change_meta() { sed -n "s/^$2=//p" "$VH_CHANGES/$1/meta" 2>/dev/null; } # change_meta ID KEY

# ---------- 变更记录清理 ----------
# 自动保留：最近 CHANGES_KEEP 条 + 最近 CHANGES_KEEP_DAYS 天内的全部记录，其余在下次修改前自动删除。
# 正在防锁死保护中、或一小时内创建且未完成的记录永远不会被删除。
CHANGES_KEEP=${CHANGES_KEEP:-50}
CHANGES_KEEP_DAYS=${CHANGES_KEEP_DAYS:-90}

change_ids() { # 从新到旧
  find "$VH_CHANGES" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
    grep -E '^[0-9]{8}-[0-9]{6}-[0-9]+$' | sort -r
}

change_protected() { # 0=受保护（不能删）
  local id=$1 d="$VH_CHANGES/$1"
  systemctl is-active --quiet "vhm-guard-$id.timer" 2>/dev/null && return 0
  [[ $(cat "$d/status" 2>/dev/null) == pending && -n $(find "$d" -maxdepth 0 -mmin -60 2>/dev/null) ]] && return 0
  return 1
}

change_delete() {
  local id=$1
  [[ $id =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ && -d $VH_CHANGES/$id ]] || return 1
  change_protected "$id" && return 1
  rm -rf -- "${VH_CHANGES:?}/$id"
}

change_prune() {
  local cutoff n=0 id
  [[ -d $VH_CHANGES ]] || return 0
  cutoff=$(date -d "-$CHANGES_KEEP_DAYS days" '+%Y%m%d' 2>/dev/null) || return 0
  while IFS= read -r id; do
    n=$((n + 1))
    ((n <= CHANGES_KEEP)) && continue
    [[ ${id:0:8} > "$cutoff" || ${id:0:8} == "$cutoff" ]] && continue
    change_delete "$id" || true
  done < <(change_ids)
  return 0
}

# 1Panel 面板变更的回滚：记录目录中的 panel.prev 保存修改前的端口与监听方式
panel_restore() {
  local d=$1 port listen cur
  [[ -f $d/panel.prev ]] || return 0
  port=$(conf_get PORT "$d/panel.prev" || true)
  listen=$(conf_get LISTEN "$d/panel.prev" || true)
  if [[ -n $listen ]]; then
    panel_listen "$listen" >/dev/null || return 1
  fi
  if [[ -n $port ]]; then
    cur=$(panel_port_of "$(panel_url)")
    [[ $cur == "$port" ]] || panel_set_port "$port" >/dev/null || return 1
  fi
}

run_hooks() { # run_hooks 记录目录 钩子...
  local d=$1 h rc=0
  shift
  for h in "$@"; do
    case $h in
      sshd) ssh_reload || rc=1 ;;
      fail2ban) f2b_reload || rc=1 ;;
      sysctl) sysctl_restore "$d" || rc=1 ;;
      vw) vw_restart_check || rc=1 ;;
      panel) panel_restore "$d" || rc=1 ;;
      firewall) bash "$VH_DIR/vh-firewall.sh" restore "$d" || rc=1 ;;
    esac
  done
  return $rc
}

# 回滚一条变更；按记录加锁，重复调用无副作用（守护定时器与前台可能同时触发）
change_rollback() {
  local id=$1 d="$VH_CHANGES/$1" st hooks rc=0 acquired_vbm=0
  [[ $id =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ && -d $d ]] || { log_err "找不到变更记录：$id"; return 1; }
  exec 7>"$d/.lock" || return 1
  flock -w 60 7 || { log_err "变更 $id 正在被处理"; exec 7>&-; return 1; }
  st=$(cat "$d/status" 2>/dev/null) || { log_err "无法读取变更 $id 的状态"; exec 7>&-; return 1; }
  if [[ $st == rolled_back ]]; then
    log_info "变更 $id 已经回滚过"
    exec 7>&-
    return 0
  fi
  if [[ ${VH_ROLLBACK_PENDING_ONLY:-0} == 1 && $st != pending ]]; then
    log_info "变更 $id 状态为 $st（已确认保留），自动回滚取消"
    exec 7>&-
    return 0
  fi
  hooks=$(change_meta "$id" HOOKS)
  if [[ " $hooks " == *" vw "* && ${2:-} != vbm-lock-held ]]; then
    vbm_lock_hold || { exec 7>&-; return 1; }
    acquired_vbm=1
  fi
  change_restore_files "$d" || rc=1
  # shellcheck disable=SC2086
  run_hooks "$d" $hooks || rc=1
  if ((acquired_vbm)); then vbm_lock_release; fi
  if ((rc == 0)); then
    change_write_status "$d" rolled_back || { log_err "变更 $id 的文件已恢复，但无法记录回滚状态"; exec 7>&-; return 1; }
  else
    change_write_status "$d" rollback_failed || { log_err "变更 $id 回滚失败，也无法记录状态，请在 [25] 检查"; exec 7>&-; return 1; }
  fi
  exec 7>&-
  if ((rc == 0)); then
    log_ok "已回滚变更 $id（$(change_meta "$id" DESC)）"
  else
    log_err "变更 $id 回滚时出现错误，记录标记为「回滚失败」，修复上面的问题后可在 [25] 重试"
  fi
  return $rc
}

# 用户确认保留时先「认领」变更：在记录锁内把 pending 改为 confirmed。
# 与定时器回滚共用同一把记录锁且回滚前在锁内复查状态，确认与回滚不会竞态：
# 认领先完成则自动回滚取消；回滚先完成则认领失败并提示确认太晚。
# 返回 0 表示已保存确认状态。
change_claim_confirmed() {
  local id=$1 d="$VH_CHANGES/$1" st rc=1
  [[ -d $d ]] || return 1
  exec 7>"$d/.lock" || return 1
  flock -w 60 7 || { exec 7>&-; return 1; }
  st=$(cat "$d/status" 2>/dev/null) || st=""
  case $st in
    pending) change_write_status "$d" confirmed && rc=0 ;;
    confirmed) rc=0 ;;
  esac
  exec 7>&-
  return "$rc"
}

# 是否有更新的变更改过同一批文件（自动回滚此时会覆盖新配置）
change_newer_overlap() {
  local id=$1 other d p st
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    for d in "$VH_CHANGES"/*; do
      [[ -d $d ]] || continue
      other=${d##*/}
      [[ $other =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ && $other > $id ]] || continue
      st=$(cat "$d/status" 2>/dev/null)
      case $st in applied | confirmed | pending) ;; *) continue ;; esac
      awk -F'\t' -v p="$p" '$5 == p { found = 1 } END { exit !found }' "$d/files.tsv" 2>/dev/null && return 0
    done
  done < <(awk -F'\t' '{ print $5 }' "$VH_CHANGES/$id/files.tsv" 2>/dev/null)
  return 1
}

# 自动回滚一条变更：只处理仍为 pending 的记录（用户已确认的不会被回滚），
# 之后若有新的变更改过同一批文件则取消，避免覆盖新配置。change_auto_rollback ID [原因]
change_auto_rollback() {
  local id=${1:-}
  [[ $id =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ && -d $VH_CHANGES/$id ]] || return 1
  [[ $(cat "$VH_CHANGES/$id/status" 2>/dev/null) == pending ]] || return 0
  if change_newer_overlap "$id"; then
    log_warn "变更 $id 之后已有新的变更修改了同一批文件，自动回滚取消；请人工确认后在 [25] 处理"
    return 0
  fi
  log_warn "变更 $id ${2:-在保护时间内未被确认}，自动回滚"
  VH_ROLLBACK_PENDING_ONLY=1 change_rollback "$id"
}

# 开机时调用：保护期内重启会让临时定时器失效，这里把仍未确认的受保护变更回滚（从新到旧）
change_boot_rollback() {
  local id rc=0
  while IFS= read -r id; do
    [[ -f $VH_CHANGES/$id/guard && $(cat "$VH_CHANGES/$id/status" 2>/dev/null) == pending ]] || continue
    change_auto_rollback "$id" "在防锁死保护期内发生了重启" || rc=1
  done < <(change_ids)
  return $rc
}

# 常驻的开机回滚服务：内容不同才重写，已启用则不重复启用
GUARD_BOOT_UNIT=${GUARD_BOOT_UNIT:-/etc/systemd/system/vhm-guard-boot.service}
guard_boot_unit_text() {
  cat <<EOF
[Unit]
Description=Roll back unconfirmed vhm SSH changes after a reboot
After=network.target ssh.service sshd.service ssh.socket
[Service]
Type=oneshot
ExecStart=/bin/bash $VH_DIR/vh-changes.sh boot-rollback
TimeoutStartSec=600
[Install]
WantedBy=multi-user.target
EOF
}
guard_boot_install() {
  local rc=0
  unit_write "$GUARD_BOOT_UNIT" "$(guard_boot_unit_text)" || rc=$?
  ((rc != 2)) || return 1
  if ((rc == 0)); then systemctl daemon-reload || return 1; fi
  systemctl is-enabled --quiet "${GUARD_BOOT_UNIT##*/}" 2>/dev/null || systemctl enable --quiet "${GUARD_BOOT_UNIT##*/}"
}

# SSH 类变更的防锁死保护：到时未确认则由 systemd 定时器自动回滚（当前会话不受影响）；
# 保护期内重启时，由开机回滚服务接手（记录目录中的 guard 文件表示该变更受保护）
guard_start() {
  if ! command -v systemd-run >/dev/null 2>&1; then
    log_err "缺少 systemd-run，未修改 SSH 配置"
  elif ! guard_boot_install; then
    log_err "无法启用开机回滚服务 ${GUARD_BOOT_UNIT##*/}，未修改 SSH 配置"
  elif ! : >"$CHG_DIR/guard"; then
    log_err "无法标记防锁死记录，未修改 SSH 配置"
  elif systemd-run --quiet --unit="vhm-guard-$CHG_ID" --on-active="$GUARD_SECONDS" --timer-property=AccuracySec=1s \
    --property=TimeoutStartSec=infinity \
    --setenv=VH_CONF="$VH_CONF" --setenv=VH_STATE="$VH_STATE" --setenv=VH_LOG="$VH_LOG" \
    --setenv=VH_LOCK="$VH_LOCK" --setenv=VH_CHANGES="$VH_CHANGES" \
    /bin/bash "$VH_DIR/vh-changes.sh" auto-rollback "$CHG_ID"; then
    return 0
  else
    log_err "无法启动自动回滚定时器，未修改 SSH 配置"
  fi
  change_status rolled_back || log_err "无法关闭未应用的变更记录，请在 [25] 检查"
  return 1
}
guard_stop() { systemctl stop "vhm-guard-$CHG_ID.timer" >/dev/null 2>&1 || true; }

guard_abort() {
  change_rollback "$CHG_ID" || return 1
  guard_stop
}

guard_confirm() {
  if ! change_claim_confirmed "$CHG_ID"; then
    case $(cat "$CHG_DIR/status" 2>/dev/null) in
      rollback_failed) log_err "自动回滚失败，配置可能处于不一致状态，请立即用 VNC 登录检查并在 [25] 重试回滚。" ;;
      rolled_back) log_err "确认太晚，已经自动回滚。" ;;
      *) log_err "无法保存确认状态，回滚保护未取消。请保持当前窗口并检查 [25]。" ;;
    esac
    return 1
  fi
  guard_stop
}

# 返回 0 表示用户同意保留，调用者完成修改后再确认状态。
guard_wait_confirm() {
  local ans="" mins=$((GUARD_SECONDS / 60))
  echo
  printf '%s已启用 %s 分钟自动回滚保护。%s\n' "$C_Y" "$mins" "$C_0"
  echo "请【保持当前窗口不要关闭】，另开一个终端窗口按新方式登录服务器。"
  [[ -n ${1:-} ]] && echo "测试命令：$1"
  echo "登录成功后回到这里输入 yes 保留更改；输入其他内容会立即回滚；${mins} 分钟内无操作将自动回滚。"
  echo "保护期内机器重启时，开机后会自动回滚这次修改。"
  if read -r -t "$GUARD_SECONDS" -p "新窗口登录成功了吗？输入 yes 保留: " ans && [[ ${ans,,} == yes ]]; then
    return 0
  fi
  echo
  log_warn "未确认，正在回滚……"
  guard_abort
  return 1
}
