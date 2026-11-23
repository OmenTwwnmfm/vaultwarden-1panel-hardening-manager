#!/usr/bin/env bash
# 启动器：依赖检查后转交菜单或子命令
set -Eeuo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

check_deps() {
  local missing=() c
  for c in docker flock sed awk stat sha256sum python3 curl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  command -v systemctl >/dev/null 2>&1 || log_warn "未检测到 systemd，定时巡检不可用"
  command -v ss >/dev/null 2>&1 || log_warn "未检测到 ss（iproute2），P-01 面板端口检查将不准确"
  command -v git >/dev/null 2>&1 || log_warn "未检测到 git，[23] 源码更新不可用"
  [[ -d /opt/1panel ]] || log_warn "未检测到 /opt/1panel，1Panel 相关检查将标记为 unknown"
  if ((${#missing[@]})); then
    log_err "缺少依赖：${missing[*]}"
    echo "  Debian/Ubuntu: apt-get install -y util-linux coreutils python3 curl iproute2" >&2
    return 1
  fi
  log_ok "依赖齐全"
}

case "${1:-menu}" in
  --version | version) echo "vhm $VH_VERSION" ;;
  deps) check_deps ;;
  menu) need_root; exec bash "$VH_DIR/vh-manager.sh" ;;
  audit) shift; exec bash "$VH_DIR/vh-audit.sh" "$@" ;;
  plan) shift; exec bash "$VH_DIR/vh-plan.sh" "$@" ;;
  apply) shift; need_root; exec bash "$VH_DIR/vh-apply.sh" "$@" ;;
  rollback) shift; need_root; exec bash "$VH_DIR/vh-rollback.sh" "$@" ;;
  report) shift; exec bash "$VH_DIR/vh-report.sh" "$@" ;;
  watch) shift; exec bash "$VH_DIR/vh-watch.sh" "$@" ;;
  diagnose) shift; exec bash "$VH_DIR/vh-diagnose.sh" "$@" ;;
  -h | --help | help)
    cat <<EOF
vhm $VH_VERSION — Vaultwarden (1Panel) 加固管理器
用法: vhm [menu|audit|plan|apply|rollback|report|watch|diagnose|deps|version]
EOF
    ;;
  *) die "未知子命令：$1（vhm help 查看用法）" ;;
esac
