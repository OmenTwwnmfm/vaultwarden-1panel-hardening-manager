#!/usr/bin/env bash
# 断言锁冲突以 75 退出且不删除他人锁
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
VH_LOCK=$(mktemp)
export VH_LOCK VH_LOG=/dev/null
exec 8>"$VH_LOCK"
flock -n 8
bash -c 'source scripts/vh-common.sh; with_lock true' >/dev/null 2>&1
rc=$?
if [[ $rc -eq 75 && -e $VH_LOCK ]]; then
  echo "PASS lock-skip"
else
  echo "FAIL rc=$rc"
  rm -f "$VH_LOCK"
  exit 1
fi
rm -f "$VH_LOCK"