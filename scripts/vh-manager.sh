#!/usr/bin/env bash
# 交互菜单：仅做分发，编号自 v0.1.0 起冻结
set -Eeuo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

run() { bash "$VH_DIR/$1" "${@:2}" || log_warn "操作结束（退出码 $?）"; }

first_setup() {
  if [[ -f "$VH_CONF" ]]; then
    log_info "已存在 $VH_CONF，将仅重新识别实例"
  else
    install -m 600 -o root -g root "$VH_DIR/hardening.conf.example" "$VH_CONF"
    log_ok "已生成 $VH_CONF"
  fi
  install -d -m 700 "$VH_STATE" "$VH_STATE/snapshots" "$VH_STATE/reports"
  if detect_instance; then
    log_ok "实例：$VW_CONTAINER  数据目录：$VW_DATA_DIR"
    sed -i -E "s|^VW_DATA_DIR=.*|VW_DATA_DIR=\"$VW_DATA_DIR\"|; s|^VW_CONTAINER=.*|VW_CONTAINER=\"$VW_CONTAINER\"|" "$VH_CONF"
  fi
}

menu() {
  cat <<EOF

==== vhm $VH_VERSION · Vaultwarden (1Panel) 加固管理器 ====
 初始化  [01] 首次配置/重新识别实例   [02] 环境与依赖检查
 审计    [03] 全量只读审计  [04] 按域审计  [05] 查看上次报告  [06] 导出报告
 加固    [07] 生成计划  [08] 查看差异  [09] 应用计划  [10] 回滚快照  [11] 管理快照
 指引    [12] 1Panel 面板  [13] OpenResty 片段  [14] Vaultwarden 参数  [15] 主机/SSH
 自动化  [16] 安装/修改定时巡检  [17] 状态  [18] 暂停  [19] 恢复  [20] 通知配置
 维护    [21] 脱敏诊断  [22] 同步后台脚本  [23] 检查源码更新
         [00] 退出
EOF
}

while true; do
  menu
  read -r -p "请选择：" c || exit 0
  case "$c" in
    0 | 00) exit 0 ;;
    01 | 1) first_setup ;;
    02 | 2) bash "$VH_DIR/vh-launcher.sh" deps || true ;;
    03 | 3) run vh-audit.sh ;;
    04 | 4) read -r -p "域（panel/exposure/app/container/host/data/supply）：" d; run vh-audit.sh --domain "$d" ;;
    05 | 5) run vh-report.sh show ;;
    06 | 6) run vh-report.sh export ;;
    07 | 7) run vh-plan.sh ;;
    08 | 8) run vh-plan.sh --diff ;;
    09 | 9) run vh-apply.sh ;;
    10) run vh-rollback.sh ;;
    11) run vh-rollback.sh --list ;;
    12) run vh-guide.sh panel ;;
    13) run vh-guide.sh openresty ;;
    14) run vh-guide.sh vaultwarden ;;
    15) run vh-guide.sh host ;;
    16) run vh-watch.sh install ;;
    17) run vh-watch.sh status ;;
    18) run vh-watch.sh pause ;;
    19) run vh-watch.sh resume ;;
    20) run vh-watch.sh notify-test ;;
    21) run vh-diagnose.sh ;;
    22) run vh-watch.sh install --sync-only ;;
    23) (cd "$VH_DIR/.." && git diff --quiet && git fetch -q origin main && git merge --ff-only origin/main) || log_warn "工作区不干净或无法快进，未更新" ;;
    *) log_warn "无效选项：$c" ;;
  esac
done
