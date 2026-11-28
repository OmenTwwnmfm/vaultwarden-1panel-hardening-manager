#!/usr/bin/env bash
# 交互菜单：顶部状态面板 + 分类菜单，只负责分发到各功能脚本
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

run() {
  local rc=0
  bash "$VH_DIR/$1" "${@:2}" || rc=$?
  ((rc == 0 || rc == 1)) || log_warn "操作结束（退出码 $rc）"
  pause
}

first_setup_apply() {
  install -d -m 700 "$VH_STATE" "$VH_CHANGES" || { log_err "无法初始化变更记录目录"; return 1; }
  if [[ -f "$VH_CONF" ]]; then
    log_info "已存在 $VH_CONF，将重新识别 Vaultwarden 实例"
  else
    install -m 600 -o root -g root "$VH_DIR/hardening.conf.example" "$VH_CONF" || { log_err "无法生成 $VH_CONF"; return 1; }
    log_ok "已生成 $VH_CONF"
  fi
  bash "$VH_DIR/vh-launcher.sh" deps || true
  vh_legacy_cleanup
  VW_DATA_DIR="" VW_CONTAINER=""
  if detect_instance "$(conf_get VW_DATA_DIR || true)"; then
    if ! kv_set "$VH_CONF" VW_DATA_DIR "$VW_DATA_DIR" || ! kv_set "$VH_CONF" VW_CONTAINER "$VW_CONTAINER"; then
      log_err "无法保存 Vaultwarden 实例到 $VH_CONF"
      return 1
    fi
    log_ok "实例：$VW_CONTAINER  数据目录：$VW_DATA_DIR"
  else
    log_warn "未能确定 Vaultwarden 实例；SSH、1Panel、Fail2Ban、体检等功能不受影响"
  fi
  if panel_installed; then
    log_ok "已检测到 1Panel $(panel_version || true)；防火墙：$(fw_label)"
  else
    log_warn "未检测到 1pctl，1Panel 面板相关功能不可用"
  fi
  if vbm_installed; then
    log_ok "已检测到 vbm：修改 Vaultwarden 设置前会自动调用它做完整备份"
  else
    log_warn "未检测到 vbm（vaultwarden-backup-manager），建议先安装再修改 Vaultwarden 设置"
  fi
}

first_setup() {
  if confirm_yes "初始化 $VH_STATE 并写入 $VH_CONF？"; then
    local rc=0
    (with_lock first_setup_apply) || rc=$?
    ((rc != VH_EXIT_LOCKED)) || log_warn "首次配置未执行（退出码 $rc）"
  fi
  pause
}

restart_menu() {
  export VHM_AUTO_UPDATE_CHECKED=1
  exec bash "$VH_DIR/vh-launcher.sh" menu
}

# 预览目标提交后要求明确确认；返回 0 表示已更新
offer_update() {
  local rc=0 target_label
  target_label=$(source_commit_label "$UPD_TARGET")
  echo
  echo "发现更新：当前 $(source_commit_label "$UPD_BEFORE") → $target_label"
  source_show_pending || return 1
  VH_ASSUME_YES=0 confirm_yes '更新到上述版本？更新后菜单会重新加载' || return 1
  source_apply || rc=$?
  ((rc == VH_SOURCE_UPDATED)) || return 1
  log_ok "已更新到 $target_label，重新进入菜单"
}

update_source() { # 菜单 [27]
  local rc=0
  log_info "正在检查 GitHub 更新……"
  source_check || rc=$?
  if ((rc == VH_SOURCE_AVAILABLE)) && offer_update; then
    pause
    restart_menu
  fi
  ((rc == 0)) && log_ok "已是最新版本（v$VH_VERSION）"
  pause
}

auto_update_source() { # 每次启动菜单时按 AUTO_UPDATE 检查一次
  [[ ${VHM_AUTO_UPDATE_CHECKED:-0} == 1 ]] && return 0
  export VHM_AUTO_UPDATE_CHECKED=1
  local rc=0
  [[ $(update_mode) == off ]] && return 0
  log_info "正在检查 GitHub 更新……"
  source_check || rc=$?
  if ((rc != VH_SOURCE_AVAILABLE)); then
    ((rc == 0)) || sleep 2
    return 0
  fi
  if offer_update; then
    sleep 2
    restart_menu
  fi
  log_info "本次未更新；可随时在 [27] 检查更新，或在 $VH_CONF 中设置 AUTO_UPDATE=off 关闭启动检查"
  sleep 2
}

# 状态面板：每项都容错，读不到就显示「未知」
status_args() {
  local port tfa pa pk f2b vw="未识别" panel="未安装"
  port=$(sshd_get port 2>/dev/null | paste -sd, -)
  if tfa_enabled 2>/dev/null; then
    tfa="已启用"
  elif tfa_pam_nullok 2>/dev/null; then
    tfa="PAM 带 nullok"
  else
    tfa="未启用"
  fi
  pa=$(sshd_get passwordauthentication 2>/dev/null)
  case $pa in yes) pa="开" ;; no) pa="关" ;; *) pa="未知" ;; esac
  pk=$(sshd_get pubkeyauthentication 2>/dev/null)
  case $pk in yes) pk="开" ;; no) pk="关" ;; *) pk="未知" ;; esac
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    f2b="运行中（封禁 $(f2b_banned || echo ?)）"
  elif command -v fail2ban-client >/dev/null 2>&1; then
    f2b="未运行"
  else
    f2b="未安装"
  fi
  if panel_installed; then
    local pp
    pp=$(panel_port_of "$(panel_url)")
    if panel_active; then panel="运行中 · 端口 ${pp:-?}"; else panel="未运行"; fi
  fi
  if load_instance >/dev/null 2>&1; then
    local sig adm
    sig=$(vw_eff signups_allowed SIGNUPS_ALLOWED true)
    [[ $sig == false ]] && sig="注册关" || sig="注册开"
    case $(vw_admin_state) in
      off) adm="后台关" ;;
      argon2) adm="后台开（哈希令牌）" ;;
      plain) adm="后台开（明文令牌）" ;;
      notoken) adm="后台免令牌（危险）" ;;
    esac
    vw="$sig · $adm"
  fi
  printf '%s\n' "$VH_VERSION" "SSH 端口：${port:-未知} · 密码登录：$pa · 密钥登录：$pk · 2FA：$tfa" \
    "1Panel：$panel · 防火墙：$(fw_label)" "Fail2Ban：$f2b · Vaultwarden：$vw"
}

render_menu() {
  local args=()
  mapfile -t args < <(status_args)
  python3 - "${args[@]}" <<'PYMENU'
import sys
import unicodedata

version, *status = sys.argv[1:]
W = 70

def width(s):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ("F", "W") else 1 for c in s)

def pad(s, align="left"):
    while width(s) > W:
        s = s[:-1]
    n = W - width(s)
    if align == "center":
        return " " * (n // 2) + s + " " * (n - n // 2)
    return s + " " * n

def row(s="", align="left"):
    if s and align == "left":
        s = "  " + s
    print("│" + pad(s, align) + "│")

def sep():
    print("├" + "─" * W + "┤")

print("╭" + "─" * W + "╮")
row("Vaultwarden Hardening Manager", "center")
row(f"v{version} · 1Panel Edition · Ubuntu / Debian", "center")
row("Powered by OmenTwwnmfm", "center")
row()
for line in status:
    row(line, "center")
sep()
sections = [
    ("01 · 快速操作", [
        "[01] 首次配置 / 识别 Vaultwarden 实例",
        "[02] VPS 安全体检（含 Docker 端口暴露）"]),
    ("02 · SSH 登录安全", [
        "[03] SSH 状态（端口、登录方式、2FA、当前会话）",
        "[04] 管理登录密钥（列出 / 添加 / 删除）",
        "[05] 修改 SSH 端口",
        "[06] SSH 登录方式（按用户选择：密码、密钥及 TOTP 组合）",
        "[07] 2FA 管理（二维码 / 重新绑定 / 应急码 / 关闭）",
        "[08] 登录记录（成功、失败、来源 IP）"]),
    ("03 · 1Panel 面板", [
        "[09] 面板状态（版本、端口、安全入口、放行范围）",
        "[10] 修改面板端口",
        "[11] 修改面板用户名 / 密码",
        "[12] 切换监听地址（IPv4 / IPv6）",
        "[13] 启动 / 停止 / 重启 1Panel",
        "[14] 应急重置（安全入口、授权 IP、两步验证等）"]),
    ("04 · 防火墙（与 1Panel 同步）", [
        "[15] 规则列表 / 添加 / 删除（支持 1Panel iptables 与 UFW）"]),
    ("05 · Fail2Ban", [
        "[16] 安装 / 修改 SSH 防护配置（端口自动同步）",
        "[17] 状态、封禁列表、解封 IP"]),
    ("06 · Vaultwarden", [
        "[18] 状态总览（注册、邀请、后台、版本）",
        "[19] 开启 / 关闭注册",
        "[20] 后台 ADMIN（开启 / 更换令牌 / 关闭）",
        "[21] 用户列表",
        "[22] 安全选项（密码提示、Send、紧急访问等）"]),
    ("07 · 系统加固", [
        "[23] 自动安全更新",
        "[24] 内核网络参数加固"]),
    ("08 · 系统维护", [
        "[25] 变更记录与回滚（含删除记录）",
        "[26] 生成脱敏诊断报告",
        "[27] 检查 / 更新项目源码"]),
]
for title, items in sections:
    row(title)
    for item in items:
        row("    " + item)
    sep()
row("[00] 退出")
print("╰" + "─" * W + "╯")
PYMENU
}

[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0
while true; do
  auto_update_source
  [[ -t 1 ]] && clear
  render_menu
  read -r -p "请选择：" c || exit 0
  case "$c" in
    0 | 00) exit 0 ;;
    01 | 1) first_setup ;;
    02 | 2) run vh-checkup.sh full ;;
    03 | 3) run vh-ssh.sh status ;;
    04 | 4) run vh-ssh.sh keys ;;
    05 | 5) run vh-ssh.sh port ;;
    06 | 6) run vh-ssh.sh auth-mode ;;
    07 | 7) run vh-ssh.sh 2fa-manage ;;
    08 | 8) run vh-ssh.sh logins ;;
    09 | 9) run vh-panel.sh status ;;
    10) run vh-panel.sh port ;;
    11) run vh-panel.sh account ;;
    12) run vh-panel.sh listen ;;
    13) run vh-panel.sh service ;;
    14) run vh-panel.sh reset ;;
    15) run vh-firewall.sh menu ;;
    16) run vh-fail2ban.sh setup ;;
    17) run vh-fail2ban.sh manage ;;
    18) run vh-vaultwarden.sh status ;;
    19) run vh-vaultwarden.sh signups ;;
    20) run vh-vaultwarden.sh admin ;;
    21) run vh-vaultwarden.sh users ;;
    22) run vh-vaultwarden.sh options ;;
    23) run vh-system.sh auto-updates ;;
    24) run vh-system.sh sysctl ;;
    25) run vh-changes.sh menu ;;
    26) run vh-diagnose.sh ;;
    27) update_source ;;
    *) log_warn "无效选项：$c"; sleep 1 ;;
  esac
done
