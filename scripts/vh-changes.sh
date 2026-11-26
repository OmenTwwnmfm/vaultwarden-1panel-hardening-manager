#!/usr/bin/env bash
# 变更记录与回滚：列出 vhm 做过的修改，按条回滚、删除记录；也供 SSH 防锁死定时器自动回滚
#
# 原理：每次修改前把要改的文件整份复制到记录目录（files/），并在 files.tsv 记下路径、权限、属主
# 以及「修改前是否存在」。回滚时把副本原样放回、删除修改前不存在的文件，再重新加载相关服务。
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

CHG_LIST=()
load_list() {
  CHG_LIST=()
  [[ -d $VH_CHANGES ]] || return 0
  mapfile -t CHG_LIST < <(change_ids)
}

status_name() {
  case $(cat "$VH_CHANGES/$1/status" 2>/dev/null) in
    applied) echo 已生效 ;;
    confirmed) echo 已确认 ;;
    rolled_back) echo 已回滚 ;;
    rollback_failed) echo 回滚失败 ;;
    pending) change_protected "$1" && echo 保护中 || echo 未完成 ;;
    *) echo 未知 ;;
  esac
}

usage_line() {
  local n=${#CHG_LIST[@]} size
  size=$(du -sh "$VH_CHANGES" 2>/dev/null | awk '{ print $1 }')
  echo "共 $n 条记录，占用 ${size:-0}。自动保留最近 $CHANGES_KEEP 条以及 $CHANGES_KEEP_DAYS 天内的记录，更早的在下次修改时自动删除。"
}

show_list() { # show_list [最多条数]
  load_list
  if ((${#CHG_LIST[@]} == 0)); then
    log_info "暂无变更记录"
    return 1
  fi
  local i id max=${1:-${#CHG_LIST[@]}}
  printf '%-5s %-20s %-8s %s\n' 序号 时间 状态 内容
  for i in "${!CHG_LIST[@]}"; do
    ((i < max)) || break
    id=${CHG_LIST[$i]}
    printf '%-5s %-20s %-8s %s\n' "$((i + 1))" "$(change_meta "$id" TIME)" "$(status_name "$id")" "$(change_meta "$id" DESC)"
  done
  ((${#CHG_LIST[@]} > max)) && echo "……（只显示最近 $max 条）"
  echo
  usage_line
}

# 解析「3 5 8-12」这样的序号列表，输出去重后的序号
parse_indexes() {
  local tok a b i
  for tok in $1; do
    if [[ $tok =~ ^[0-9]+$ ]]; then
      echo "$tok"
    elif [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
      ((a <= b)) || { local t=$a; a=$b; b=$t; }
      for ((i = a; i <= b; i++)); do echo "$i"; done
    else
      return 1
    fi
  done | sort -un
}

do_rollback() {
  local n id newer=0 i
  read -r -p "输入要回滚的序号（回车返回）: " n || return 0
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
  [[ -f $VH_CHANGES/$id/panel.prev ]] && echo "  1Panel 面板设置：$(tr '\n' ' ' <"$VH_CHANGES/$id/panel.prev")"
  for ((i = 0; i < n - 1; i++)); do
    local st
    st=$(cat "$VH_CHANGES/${CHG_LIST[$i]}/status" 2>/dev/null)
    [[ $st == applied || $st == confirmed ]] && newer=1
  done
  ((newer)) && log_warn "这条之后还有已生效的变更；如果它们改过同一个文件，回滚会一并覆盖掉后来的修改。"
  if [[ " $(change_meta "$id" HOOKS) " == *" sshd "* ]]; then
    log_warn "这是一条 SSH 相关变更。回滚后请保持当前窗口，另开窗口确认还能登录。"
  fi
  confirm_yes "确认回滚「$(change_meta "$id" DESC)」？" || return 0
  change_rollback "$id"
}

delete_ids() { # delete_ids 描述 ID...：确认后删除，返回删除条数
  local desc=$1 id ok=0 skip=0 keep=0 st
  shift
  (($#)) || { log_info "没有可删除的记录"; return 0; }
  for id in "$@"; do
    st=$(cat "$VH_CHANGES/$id/status" 2>/dev/null)
    [[ $st == applied || $st == confirmed || $st == rollback_failed ]] && keep=$((keep + 1))
  done
  echo "将删除 $# 条记录（$desc）。"
  ((keep)) && log_warn "其中 $keep 条是已生效、已确认或回滚失败的变更；删除后无法再回滚或重试（当前修改保留）。"
  confirm_yes "确认删除？" || return 0
  for id in "$@"; do
    if change_delete "$id"; then ok=$((ok + 1)); else skip=$((skip + 1)); fi
  done
  log_ok "已删除 $ok 条记录"
  ((skip)) && log_warn "$skip 条记录正在防锁死保护中或刚刚创建，已跳过"
  return 0
}

delete_menu() {
  echo
  echo "  [1] 删除指定记录（序号，可多个或范围，如 3 5 8-12）"
  echo "  [2] 删除所有「已回滚」的记录"
  echo "  [3] 只保留最近 N 条"
  echo "  [0] 返回"
  local c ids=() i idx n parsed
  read -r -p "请选择：" c || return 0
  case $c in
    1)
      read -r -p "输入序号: " n || return 0
      [[ -n $n ]] || return 0
      parsed=$(parse_indexes "$n") || { log_err "序号格式无效：$n"; return 1; }
      [[ -n $parsed ]] || { log_err "序号格式无效：$n"; return 1; }
      mapfile -t idx <<<"$parsed"
      ((${#idx[@]})) || { log_err "序号格式无效：$n"; return 1; }
      for i in "${idx[@]}"; do
        ((i >= 1 && i <= ${#CHG_LIST[@]})) || { log_err "序号超出范围：$i"; return 1; }
        ids+=("${CHG_LIST[$((i - 1))]}")
      done
      delete_ids "序号 $n" "${ids[@]}"
      ;;
    2)
      for i in "${CHG_LIST[@]}"; do
        [[ $(cat "$VH_CHANGES/$i/status" 2>/dev/null) == rolled_back ]] && ids+=("$i")
      done
      delete_ids "已回滚" "${ids[@]}"
      ;;
    3)
      n=$(read_default "保留最近几条" 10)
      [[ $n =~ ^[0-9]+$ ]] || { log_err "请输入数字"; return 1; }
      for ((i = n; i < ${#CHG_LIST[@]}; i++)); do ids+=("${CHG_LIST[$i]}"); done
      delete_ids "最近 $n 条以外" "${ids[@]}"
      ;;
  esac
}

menu() {
  while true; do
    title 变更记录与回滚
    show_list 30 || return 0
    echo
    echo "  [1] 回滚一条变更   [2] 删除记录   [0] 返回"
    local c
    read -r -p "请选择：" c || return 0
    case $c in
      1) do_rollback ;;
      2) delete_menu ;;
      *) return 0 ;;
    esac
  done
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

# 由 systemd-run 定时器调用：只回滚仍处于「未完成」的变更（用户已确认的不会被回滚）
auto_rollback() {
  local id=${1:-}
  [[ -n $id && -d $VH_CHANGES/$id ]] || exit 1
  [[ $(cat "$VH_CHANGES/$id/status" 2>/dev/null) == pending ]] || exit 0
  if change_newer_overlap "$id"; then
    log_warn "变更 $id 之后已有新的变更修改了同一批文件，自动回滚取消；请人工确认后在 [25] 处理"
    exit 0
  fi
  log_warn "变更 $id 在保护时间内未被确认，自动回滚"
  VH_ROLLBACK_PENDING_ONLY=1 change_rollback "$id"
}

case ${1:-menu} in
  menu) need_root; with_lock menu ;;
  list) show_list || true ;;
  rollback) need_root; [[ -n ${2:-} ]] || die "用法：vhm rollback <变更ID>"; with_lock change_rollback "$2" ;;
  auto-rollback) with_lock_wait 300 auto_rollback "${2:-}" ;;
  *) die "未知参数：$1" ;;
esac
