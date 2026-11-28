#!/usr/bin/env bash
# 启动器：依赖检查后转交菜单或子命令
set -Eeuo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# 与 run.sh 相同的路径安全检查，日常入口也复检：项目目录或其上级目录被
# 放宽权限后，不能仍以 root 无提示地执行其中脚本（纵深防御）。
path_component_safe() {
  local path=$1 owner
  owner=$(stat -c '%u' -- "$path" 2>/dev/null) || return 1
  [[ "$owner" == 0 || "$owner" == "$(id -u)" ]] || return 1
  [[ -z "$(find "$path" -maxdepth 0 -perm /022 -print 2>/dev/null)" ]]
}
launcher_path_safe() {
  local path=$1
  while true; do
    path_component_safe "$path" || return 1
    [[ "$path" == / ]] && break
    path=$(dirname -- "$path")
  done
}
if ! launcher_path_safe "$VH_DIR"; then
  echo "错误：项目目录或其上级目录不安全（须由 root 或当前用户所有，且不可被组/其他用户写入）：$VH_DIR" >&2
  exit 1
fi
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
  command -v git >/dev/null 2>&1 || log_warn "未检测到 git，[27] 源码更新不可用"
  if ((${#missing[@]})); then
    log_err "缺少依赖：${missing[*]}"
    echo "  Debian/Ubuntu: apt-get install -y util-linux coreutils python3 openssh-server openssh-client iproute2 curl" >&2
    return 1
  fi
  log_ok "依赖齐全"
}

usage() {
  cat <<EOF
vhm $VH_VERSION — Vaultwarden Hardening Manager

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
  access-verify <ID> <阶段>  按 [06] 迁移向导验证新的普通用户 SSH / sudo 会话
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
    vh_units_refresh
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
  access-verify) need_root; shift; exec bash "$VH_DIR/vh-access.sh" verify "$@" ;;
  diagnose) shift; exec bash "$VH_DIR/vh-diagnose.sh" "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 1 ;;
esac
