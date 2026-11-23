#!/usr/bin/env bash
# 回滚 / 列出快照（快照目录名按时间排序；与其他 vhm 任务互斥，可被 apply 重入调用）
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"
SNAPS="$VH_STATE/snapshots"

list_snaps() {
  local d found=0
  for d in "$SNAPS"/*/; do
    [[ -d "$d" ]] || continue
    d=${d%/}
    echo "${d##*/}"
    found=1
  done
  ((found)) || echo "（无快照）"
}

snap="" yes=0
while (($#)); do
  case "$1" in
    --list) list_snaps; exit 0 ;;
    --snapshot)
      [[ $# -ge 2 ]] || die "--snapshot 需要参数"
      snap=$2
      shift 2
      ;;
    --yes) yes=1; shift ;;
    *) die "未知参数：$1" ;;
  esac
done

main() {
  if [[ -z "$snap" ]]; then
    local all=("$SNAPS"/*/)
    [[ -d "${all[-1]}" ]] || die "没有可用快照"
    snap=${all[-1]%/}
  fi
  [[ -r "$snap/perms.tsv" ]] || die "快照无效：$snap"
  (cd "$snap" && sha256sum -c --quiet SHA256SUMS) || die "快照校验失败，拒绝回滚"

  log_info "回滚快照：$snap"
  if ((!yes)); then confirm_yes "将恢复快照中的权限与属主。" || exit 1; fi
  local mode owner path bad=0
  while IFS=$'\t' read -r mode owner path; do
    if [[ ! -e "$path" ]]; then
      log_warn "$path 已不存在，跳过"
      continue
    fi
    if ! { chmod "$mode" "$path" && chown "$owner" "$path"; }; then
      log_err "恢复失败：$path"
      bad=1
    fi
  done <"$snap/perms.tsv"
  ((bad == 0)) || die "部分路径回滚失败"
  log_ok "回滚完成"
}
with_lock main
