#!/usr/bin/env bash
# 断言：他人持锁时审计以 75 退出；已持锁的子进程（VH_LOCK_HELD=1）可重入
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
mk_env
trap 'rm -rf "$T"' EXIT
fail=0
exec 8>"$VH_LOCK"
flock -n 8
bash scripts/vh-audit.sh --domain data >/dev/null 2>&1
rc=$?
[[ $rc -eq 75 ]] || { echo "FAIL 审计 rc=$rc，期望 75"; fail=1; }
[[ -e "$VH_STATE/reports/latest.json" ]] && { echo "FAIL 锁冲突时不应生成报告"; fail=1; }
VH_LOCK_HELD=1 bash -c 'source scripts/vh-common.sh; with_lock true' >/dev/null 2>&1 ||
  { echo "FAIL 重入失败"; fail=1; }
((fail == 0)) && echo "PASS audit-lock"
exit $fail
