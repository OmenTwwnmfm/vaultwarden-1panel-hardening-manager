#!/usr/bin/env bash
# 断言菜单编号 01–23 齐全且冻结
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
for i in $(seq -w 1 23); do grep -q "\[$i\]" scripts/vh-manager.sh || { echo "FAIL 缺少 [$i]"; fail=1; }; done
grep -q '\[00\] 退出' scripts/vh-manager.sh || { echo "FAIL 缺少 [00]"; fail=1; }
((fail == 0)) && echo "PASS menu"; exit $fail
