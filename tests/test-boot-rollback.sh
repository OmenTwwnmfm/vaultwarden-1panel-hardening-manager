#!/usr/bin/env bash
# 断言保护期内重启后的开机回滚：只回滚带 guard 标记且仍未确认的变更；已确认、未受保护的不动；
# 之后有新变更改过同一文件时取消；确认与自动回滚互斥
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VH_STATE="$T/state" VH_LOG=/dev/null VH_LOCK="$T/lock"
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
fail=0
new_change() { # new_change 文件 新内容 [guard]
  change_begin "测试 $1" >/dev/null
  change_track "$1"
  printf '%s\n' "$2" >"$1"
  [[ ${3:-} == guard ]] && : >"$CHG_DIR/guard"
  echo "$CHG_ID"
}
printf 'a0\n' >"$T/a.conf"
printf 'b0\n' >"$T/b.conf"
printf 'c0\n' >"$T/c.conf"
printf 'd0\n' >"$T/d.conf"

guarded=$(new_change "$T/a.conf" a1 guard)
confirmed=$(new_change "$T/b.conf" b1 guard)
change_claim_confirmed "$confirmed" || { echo "FAIL 认领确认失败"; fail=1; }
unguarded=$(new_change "$T/c.conf" c1)
overlap_old=$(new_change "$T/d.conf" d1 guard)
overlap_new=$(new_change "$T/d.conf" d2)
printf 'applied\n' >"$VH_CHANGES/$overlap_new/status"

change_boot_rollback >/dev/null 2>&1 || { echo "FAIL 开机回滚返回非 0"; fail=1; }
[[ $(cat "$T/a.conf") == a0 ]] || { echo "FAIL 受保护且未确认的变更没有回滚"; fail=1; }
[[ $(cat "$VH_CHANGES/$guarded/status") == rolled_back ]] || { echo "FAIL 回滚后状态不是 rolled_back"; fail=1; }
[[ $(cat "$T/b.conf") == b1 ]] || { echo "FAIL 已确认的变更被回滚"; fail=1; }
[[ $(cat "$T/c.conf") == c1 ]] || { echo "FAIL 未受保护的变更被回滚"; fail=1; }
[[ $(cat "$T/d.conf") == d2 ]] || { echo "FAIL 回滚覆盖了之后的新变更"; fail=1; }
[[ $(cat "$VH_CHANGES/$overlap_old/status") == pending ]] || { echo "FAIL 取消回滚的记录状态被改动"; fail=1; }
[[ -n $overlap_new && -n $unguarded ]] || fail=1

# 重复执行无副作用
printf 'later\n' >"$T/a.conf"
change_boot_rollback >/dev/null 2>&1
[[ $(cat "$T/a.conf") == later ]] || { echo "FAIL 重复开机回滚覆盖了后来的修改"; fail=1; }

# 已回滚的变更不能再被确认
change_claim_confirmed "$guarded" && { echo "FAIL 已回滚的变更仍能被确认"; fail=1; }

# 开机回滚服务单元指向当前项目目录
guard_boot_unit_text | grep -Fq "ExecStart=/bin/bash $VH_DIR/vh-changes.sh boot-rollback" || { echo "FAIL 开机回滚服务路径不对"; fail=1; }
grep -Eq '^[[:space:]]+boot-rollback\)' scripts/vh-changes.sh || { echo "FAIL vh-changes.sh 不支持 boot-rollback"; fail=1; }

((fail == 0)) && echo "PASS boot-rollback"
exit $fail
