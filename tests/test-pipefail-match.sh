#!/usr/bin/env bash
# 断言 out_match 在 pipefail 下不会因 SIGPIPE 误判：匹配出现在大量输出之前时仍返回成功
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
VH_LOG=/dev/null source scripts/vh-common.sh
fail=0
# shellcheck disable=SC2329,SC2317 # 通过 out_match 间接调用
noisy() { echo "  entrance    desc"; sleep 0.2; seq 1 200000; }
out_match '^[[:space:]]+entrance[[:space:]]' noisy || { echo "FAIL 匹配被误判为失败"; fail=1; }
out_match 'not-there' noisy && { echo "FAIL 不匹配却返回成功"; fail=1; }
out_match '-j 1PANEL_BASIC' printf '%s\n' '-A INPUT -j 1PANEL_BASIC' || { echo "FAIL 以 - 开头的正则"; fail=1; }
((fail == 0)) && echo "PASS pipefail-match"
exit $fail
