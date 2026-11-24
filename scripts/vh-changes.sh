#!/usr/bin/env bash
# 变更记录与回滚：列出 vhm 做过的修改，按条回滚；也供 SSH 防锁死定时器自动回滚
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

CHG_LIST=()
load_list() {
  CHG_LIST=()
  [[ -d $VH_CHANGES ]] || return 0
  mapfile -t CHG_LIST < <(find "$VH_CHANGES" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
    grep -E '^[0-9]{8}-[0-9]{6}-[0-9]+$' | sort -r | head -n 30)
}

status_name() {
  case $(cat "$VH_CHANGES/$1/status" 2>/dev/null) in
    applied) echo 已生效 ;;
    rolled_back) echo 已回滚 ;;
    pending) echo 未完成 ;;
    *) echo 未知 ;;
  esac
}

show_list() {
  load_list
  if ((${#CHG_LIST[@]} == 0)); then
    log_info "暂无变更记录"
    return 1
  fi
  local i id
  printf '%-5s %-20s %-8s %s\n' 序号 时间 状态 内容
  for i in "${!CHG_LIST[@]}"; do
    id=${CHG_LIST[$i]}
    printf '%-5s %-20s %-8s %s\n' "$((i + 1))" "$(change_meta "$id" TIME)" "$(status_name "$id")" "$(change_meta "$id" DESC)"
  done
}

menu() {
  title 变更记录与回滚
  show_list || return 0
  echo
  echo "只显示最近 30 条。回滚会把该次修改涉及的文件恢复到修改前，并重新加载相关服务。"
  local n id newer=0 i
  read -r -p "输入要回滚的序号（直接回车返回）: " n || return 0
  [[ -z $n ]] && return 0
  if ! [[ $n =~ ^[0-9]+$ ]] || ((n < 1 || n > ${#CHG_LIST[@]})); then
    log_err "无效序号：$n"
    return 1
  fi
  id=${CHG_LIST[$((n - 1))]}
  if [[ $(cat "$VH_CHANGES/$id/status" 2>/dev/null) == rolled_back ]]; then
    log_info "这条变更已经回滚过"
    return 0
  fi
  echo "将恢复以下文件到修改前的状态："
  awk -F'\t' '{ print "  " $5 ($2 == 0 ? "（修改前不存在，将删除）" : "") }' "$VH_CHANGES/$id/files.tsv"
  for ((i = 0; i < n - 1; i++)); do
    [[ $(cat "$VH_CHANGES/${CHG_LIST[$i]}/status" 2>/dev/null) == applied ]] && newer=1
  done
  ((newer)) && log_warn "这条之后还有已生效的变更；如果它们改过同一个文件，回滚会一并覆盖掉后来的修改。"
  if [[ " $(change_meta "$id" HOOKS) " == *" sshd "* ]]; then
    log_warn "这是一条 SSH 相关变更。回滚后请保持当前窗口，另开窗口确认还能登录。"
  fi
  confirm_yes "确认回滚「$(change_meta "$id" DESC)」？" || return 0
  with_lock change_rollback "$id"
}

# 由 systemd-run 定时器调用：只回滚仍处于「未完成」的变更（用户已确认的不会被回滚）
auto_rollback() {
  local id=${1:-}
  [[ -n $id && -d $VH_CHANGES/$id ]] || exit 1
  [[ $(cat "$VH_CHANGES/$id/status" 2>/dev/null) == pending ]] || exit 0
  log_warn "变更 $id 在保护时间内未被确认，自动回滚"
  change_rollback "$id"
}

case ${1:-menu} in
  menu) need_root; menu ;;
  list) show_list || true ;;
  rollback) need_root; [[ -n ${2:-} ]] || die "用法：vhm changes rollback <变更ID>"; with_lock change_rollback "$2" ;;
  auto-rollback) auto_rollback "${2:-}" ;;
  *) die "未知参数：$1" ;;
esac
