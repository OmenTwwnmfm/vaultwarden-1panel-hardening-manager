#!/usr/bin/env bash
# 应用计划中 mode=auto 的条目：快照 → 修改 → 健康闸门 → 失败自动回滚
# 说明：当前唯一的 auto 项 D-02 只修改主机文件权限、不触及容器，因此不调用 vbm 备份。
#       新增涉及容器的 auto 项之前，必须先接入 vbm 备份与 vbm 锁检查。
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

plan="$VH_STATE/plan.json"
[[ -r "$plan" ]] || die "没有计划，请先运行 [07]"
mapfile -t AUTO < <(python3 -c 'import json,sys; [print(i["id"]) for i in json.load(open(sys.argv[1]))["items"] if i["mode"]=="auto"]' "$plan")
((${#AUTO[@]})) || { log_info "计划中没有可自动执行的条目"; exit 0; }

# 健康闸门：每 2 秒探测一次，连续 2 次成功即通过；超时（默认 120 秒）判失败
health_gate() {
  local ok=0 t=0 limit=${VH_HEALTH_TIMEOUT:-120}
  while ((t < limit)); do
    if docker exec "$VW_CONTAINER" /healthcheck.sh >/dev/null 2>&1; then
      ((++ok >= 2)) && return 0
    else
      ok=0
    fi
    sleep 2
    ((t += 2))
  done
  return 1
}

main() {
  load_instance || exit 2
  log_info "将自动执行：${AUTO[*]}"
  confirm_yes "即将修改主机文件权限。" || exit 1

  local snap p
  snap="$VH_STATE/snapshots/$(date +%Y%m%d-%H%M%S)-$$"
  install -d -m 700 "$snap"
  while IFS= read -r p; do
    printf '%s\t%s\t%s\n' "$(stat -c '%a' "$p")" "$(stat -c '%u:%g' "$p")" "$p"
  done < <(vw_sensitive_paths) >"$snap/perms.tsv"
  (cd "$snap" && sha256sum perms.tsv >SHA256SUMS)
  chmod 600 "$snap/perms.tsv" "$snap/SHA256SUMS"
  log_ok "快照：$snap"

  local done_ids=() failed=() id okp path
  for id in "${AUTO[@]}"; do
    case "$id" in
      D-02)
        okp=1
        while IFS=$'\t' read -r _ _ path; do chmod o-rwx "$path" || okp=0; done <"$snap/perms.tsv"
        if ((okp)); then done_ids+=("$id"); else failed+=("$id"); fi
        ;;
      *) log_warn "$id 无自动实现，跳过" ;;
    esac
  done

  if docker inspect "$VW_CONTAINER" >/dev/null 2>&1 && ! health_gate; then
    log_err "健康检查失败，自动回滚"
    bash "$VH_DIR/vh-rollback.sh" --snapshot "$snap" --yes
    exit 1
  fi
  log_ok "已改：${done_ids[*]:-无}  失败：${failed[*]:-无}"
  ((${#failed[@]} == 0)) || exit 1
}
with_lock main
