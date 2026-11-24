#!/usr/bin/env bash
# 断言变更记录：修改前备份、回滚恢复内容与权限、新建文件回滚后删除、重复回滚无副作用
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VH_STATE="$T/state" VH_LOG=/dev/null VH_LOCK="$T/lock"
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
fail=0
printf 'old\n' >"$T/a.conf"
chmod 640 "$T/a.conf"
change_begin "测试变更" >/dev/null
change_track "$T/a.conf"
change_track "$T/a.conf" # 同一路径只记录一次
change_track "$T/new.conf"
printf 'new\n' >"$T/a.conf"
chmod 644 "$T/a.conf"
printf 'x\n' >"$T/new.conf"
change_status applied
[[ $(wc -l <"$CHG_DIR/files.tsv") -eq 2 ]] || { echo "FAIL 重复记录"; fail=1; }
change_rollback "$CHG_ID" >/dev/null 2>&1 || { echo "FAIL 回滚返回非 0"; fail=1; }
[[ $(cat "$T/a.conf") == old ]] || { echo "FAIL 内容未恢复"; fail=1; }
[[ $(stat -c %a "$T/a.conf") == 640 ]] || { echo "FAIL 权限未恢复"; fail=1; }
[[ ! -e $T/new.conf ]] || { echo "FAIL 新建文件未删除"; fail=1; }
[[ $(cat "$CHG_DIR/status") == rolled_back ]] || { echo "FAIL 状态未更新"; fail=1; }
printf 'later\n' >"$T/a.conf"
change_rollback "$CHG_ID" >/dev/null 2>&1
[[ $(cat "$T/a.conf") == later ]] || { echo "FAIL 重复回滚覆盖了后来的修改"; fail=1; }
change_rollback "bad/../id" >/dev/null 2>&1 && { echo "FAIL 接受了非法 ID"; fail=1; }
mkdir "$T/dir.conf"
change_begin "目录" >/dev/null
change_track "$T/dir.conf" 2>/dev/null && { echo "FAIL 接受了目录"; fail=1; }
((fail == 0)) && echo "PASS change-rollback"
exit $fail
