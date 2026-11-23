#!/usr/bin/env bash
# 断言 yes 不区分大小写，其他输入取消
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
VH_LOG=/dev/null source scripts/vh-common.sh
fail=0
for a in yes YES Yes; do confirm_yes x <<<"$a" >/dev/null 2>&1 || { echo "FAIL accept $a"; fail=1; }; done
for a in no y '' yess; do confirm_yes x <<<"$a" >/dev/null 2>&1 && { echo "FAIL reject '$a'"; fail=1; }; done
confirm_yes x </dev/null >/dev/null 2>&1 && { echo "FAIL eof"; fail=1; }
((fail == 0)) && echo "PASS confirmation"; exit $fail
