# shellcheck shell=bash
# shellcheck disable=SC2034
# 旧版清理；由 vh-common.sh 加载，不要单独执行

# ---------- 旧版清理 ----------
# v0.1.x 的定时巡检与后台脚本副本已移除；升级后首次运行时清理
vh_legacy_cleanup() {
  local u found=0 old=/usr/local/lib/vaultwarden-hardening
  for u in vaultwarden-hardening-watch.timer vaultwarden-hardening-watch.service; do
    if [[ -f /etc/systemd/system/$u ]]; then
      found=1
      systemctl disable --now "$u" >/dev/null 2>&1 || true
      rm -f -- "/etc/systemd/system/$u"
    fi
  done
  if ((found)); then
    systemctl daemon-reload || true
    log_info "已移除 v0.1.x 的定时巡检（vaultwarden-hardening-watch）"
  fi
  if [[ -d $old/scripts && ! -L $old ]]; then
    rm -rf -- "$old" && log_info "已移除 v0.1.x 的后台脚本副本 $old"
  fi
  return 0
}

# vhm 安装的 systemd 单元直接调用项目目录中的脚本。每次进入菜单时按当前代码与项目位置重新生成已安装的单元：
# 项目被移动或重新克隆到别处后路径会被修正，升级后单元内容（如同步间隔）也随之更新。只处理已经安装过的单元。
vh_units_refresh() {
  # 启动器开启了 set -e：返回值 1（无需改写）必须用 || 接住，不能让它中断启动
  local f2b=1 guard=1
  if [[ -f $F2B_SYNC_SERVICE && ! -L $F2B_SYNC_SERVICE ]]; then
    f2b=0
    f2b_sync_units_write || f2b=$?
  fi
  if [[ -f $GUARD_BOOT_UNIT && ! -L $GUARD_BOOT_UNIT ]]; then
    guard=0
    unit_write "$GUARD_BOOT_UNIT" "$(guard_boot_unit_text)" || guard=$?
  fi
  ((f2b == 2 || guard == 2)) && log_warn "无法更新 vhm 的 systemd 单元，请检查 /etc/systemd/system 是否可写"
  ((f2b == 0 || guard == 0)) || return 0
  systemctl daemon-reload >/dev/null 2>&1 || true
  if ((f2b == 0)); then systemctl try-restart vhm-ssh-port-sync.path vhm-ssh-port-sync.timer >/dev/null 2>&1 || true; fi
  log_info "已按当前版本更新 vhm 的 systemd 单元（项目目录：$VH_DIR）"
  return 0
}
