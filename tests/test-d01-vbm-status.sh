#!/usr/bin/env bash
# 断言 D-01：failed: 0 判 pass；超期/失败/非零退出码/未安装 判 fail
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
mk_env
trap 'rm -rf "$T"' EXIT
fail=0
check() { # 输出 退出码 期望
  export VBM_OUT=$1 VBM_RC=$2
  run_audit data
  local got
  got=$(field D-01)
  [[ $got == "$3" ]] || { echo "FAIL out='$1' rc=$2 期望 $3 实际 $got"; fail=1; }
}
stub vbm 'printf "%b" "${VBM_OUT:-}"; exit "${VBM_RC:-0}"'
check '上次备份：2026-11-23 成功\nfailed: 0' 0 pass
check '最近一次：成功\n失败：0' 0 pass
check '备份已超期 3 天' 0 fail
check 'Last backup: FAILED' 0 fail
check '' 3 fail
rm -f "$T/bin/vbm"
if ! command -v vbm >/dev/null 2>&1; then check '' 0 fail; fi
((fail == 0)) && echo "PASS d01-vbm-status"
exit $fail
