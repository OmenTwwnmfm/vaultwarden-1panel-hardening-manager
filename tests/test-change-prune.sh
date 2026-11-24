#!/usr/bin/env bash
# 断言变更记录自动清理：保留最近 N 条 + 最近 D 天内的记录；刚创建且未完成的记录不会被删除；非法 ID 拒绝删除
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VH_STATE="$T/state" VH_LOG=/dev/null CHANGES_KEEP=2 CHANGES_KEEP_DAYS=30
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
fail=0
mk() { # mk 日期 状态
  local d="$VH_CHANGES/$1-000000-1"
  mkdir -p "$d/files"
  : >"$d/files.tsv"
  printf 'ID=%s\nTIME=x\nDESC=t\nHOOKS=\n' "$1-000000-1" >"$d/meta"
  echo "$2" >"$d/status"
}
old=$(date -d '-200 days' +%Y%m%d)
older=$(date -d '-300 days' +%Y%m%d)
oldest=$(date -d '-400 days' +%Y%m%d)
recent=$(date -d '-5 days' +%Y%m%d)
mk "$oldest" applied
mk "$older" rolled_back
mk "$old" pending # 刚创建（mtime 为现在）且未完成：受保护
mk "$recent" applied
mk "$(date -d '-1 days' +%Y%m%d)" applied
change_prune
have() { [[ -d "$VH_CHANGES/$1-000000-1" ]]; }
have "$recent" || { echo "FAIL 删除了 30 天内的记录"; fail=1; }
have "$old" || { echo "FAIL 删除了受保护的未完成记录"; fail=1; }
have "$older" && { echo "FAIL 未删除过期的已回滚记录"; fail=1; }
have "$oldest" && { echo "FAIL 未删除过期的已生效记录"; fail=1; }
change_delete "../../etc" && { echo "FAIL 接受了非法 ID"; fail=1; }
change_delete "$recent-000000-1" || { echo "FAIL 无法删除指定记录"; fail=1; }
have "$recent" && { echo "FAIL 指定删除未生效"; fail=1; }
((fail == 0)) && echo "PASS change-prune"
exit $fail
