#!/usr/bin/env bash
# 启动器：依赖检查后转交菜单或子命令
set -Eeuo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

check_deps() {
  local missing=() c
  for c in flock sed awk stat python3 ssh-keygen systemctl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ -x $SSHD_BIN ]] || missing+=(sshd)
  command -v docker >/dev/null 2>&1 || log_warn "未检测到 docker，Vaultwarden 与 Docker 相关功能不可用"
  command -v ss >/dev/null 2>&1 || log_warn "未检测到 ss（iproute2），端口检查不可用"
  command -v systemd-run >/dev/null 2>&1 || log_warn "未检测到 systemd-run，SSH 相关修改无法启用防锁死保护，将被拒绝"
  command -v curl >/dev/null 2>&1 || log_warn "未检测到 curl，Docker 端口实测不可用"
  command -v git >/dev/null 2>&1 || log_warn "未检测到 git，[26] 源码更新不可用"
  if ((${#missing[@]})); then
    log_err "缺少依赖：${missing[*]}"
    echo "  Debian/Ubuntu: apt-get install -y util-linux coreutils python3 openssh-server openssh-client iproute2 curl" >&2
    return 1
  fi
  log_ok "依赖齐全"
}

usage() {
  cat <<EOF
vhm $VH_VERSION — VPS & Vaultwarden (1Panel) 加固管理器

用法: sudo vhm [子命令]
  （无参数）            进入交互菜单
  checkup              VPS 安全体检（只读）
  ports                端口暴露检查（只读）
  panel-status         1Panel 面板状态（只读）
  ssh-status           SSH 状态（只读）
  vw-status            Vaultwarden 状态（只读）
  vw-users             Vaultwarden 用户列表（只读）
  changes              列出变更记录
  rollback <变更ID>    回滚一条变更
  diagnose             脱敏诊断报告
  deps                 依赖检查
  version              显示版本

所有修改操作只在交互菜单中提供，执行前需要输入 yes 确认。
EOF
}

case "${1:-menu}" in
  --version | version) echo "vhm $VH_VERSION" ;;
  deps) check_deps ;;
  menu)
    need_root
    [[ -t 0 ]] || die "这是交互式菜单，请在 SSH 终端中运行"
    vh_legacy_cleanup
    exec bash "$VH_DIR/vh-manager.sh"
    ;;
  checkup) need_root; exec bash "$VH_DIR/vh-checkup.sh" full ;;
  ports) need_root; exec bash "$VH_DIR/vh-checkup.sh" ports ;;
  panel-status) need_root; exec bash "$VH_DIR/vh-panel.sh" status ;;
  ssh-status) need_root; exec bash "$VH_DIR/vh-ssh.sh" status ;;
  vw-status) need_root; exec bash "$VH_DIR/vh-vaultwarden.sh" status ;;
  vw-users) need_root; exec bash "$VH_DIR/vh-vaultwarden.sh" users ;;
  changes) need_root; exec bash "$VH_DIR/vh-changes.sh" list ;;
  rollback) need_root; shift; exec bash "$VH_DIR/vh-changes.sh" rollback "${1:-}" ;;
  diagnose) shift; exec bash "$VH_DIR/vh-diagnose.sh" "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 1 ;;
esac
