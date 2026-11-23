#!/usr/bin/env bash
# 只读审计：全程不修改被审计对象，仅在 VH_STATE/reports 写报告；与其他 vhm 任务互斥
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"
# shellcheck source=scripts/checks/_lib.sh
source "$VH_DIR/checks/_lib.sh"

domain_filter="" out_dir="$VH_STATE/reports"
while (($#)); do
  case "$1" in
    --domain | --out)
      [[ $# -ge 2 ]] || die "$1 需要参数"
      if [[ $1 == --domain ]]; then domain_filter=$2; else out_dir=$2; fi
      shift 2
      ;;
    *) die "未知参数：$1" ;;
  esac
done

declare -A MAP=([panel]=10 [exposure]=20 [app]=30 [container]=40 [host]=50 [data]=60 [supply]=70)
if [[ -n "$domain_filter" && -z "${MAP[$domain_filter]:-}" ]]; then
  die "未知域：$domain_filter（可选：${!MAP[*]}）"
fi

main() {
  if ! load_instance; then
    log_err "无法确定实例，审计中止"
    exit 2
  fi
  mkdir -p "$out_dir"
  VH_RESULTS=$(mktemp)
  export VH_RESULTS
  trap 'rm -f "$VH_RESULTS"' EXIT

  log_info "审计实例 ${VW_CONTAINER:-?}（$VW_DATA_DIR）"
  local f
  for f in "$VH_DIR"/checks/[0-9]*.sh; do
    if [[ -n "$domain_filter" && "$(basename "$f")" != "${MAP[$domain_filter]}-"* ]]; then continue; fi
    # shellcheck source=/dev/null
    source "$f" || log_warn "检查脚本 $(basename "$f") 异常"
  done

  local ts json md
  ts=$(date +%Y%m%d-%H%M%S)
  json="$out_dir/report-$ts.json"
  md="$out_dir/report-$ts.md"
  python3 "$VH_DIR/vh_rules.py" report "$VH_RESULTS" "$json" "$md" || die "生成报告失败"
  chmod 600 "$json" "$md"
  ln -sfn "$json" "$out_dir/latest.json"
  ln -sfn "$md" "$out_dir/latest.md"
  log_ok "报告：$md"
}
with_lock main
