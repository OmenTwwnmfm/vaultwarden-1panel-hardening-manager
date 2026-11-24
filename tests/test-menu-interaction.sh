#!/usr/bin/env bash
# 断言菜单 [01]–[26] 齐全、每个编号都有分发分支，且分发到的脚本与子命令存在
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
m=scripts/vh-manager.sh
fail=0
for i in $(seq -w 1 26); do
  grep -q "\"\[$i\] " "$m" || { echo "FAIL 菜单缺少 [$i]"; fail=1; }
  n=$((10#$i))
  grep -Eq "^[[:space:]]+($i \| $n|$i)\) " "$m" || { echo "FAIL 缺少 [$i] 的分发分支"; fail=1; }
done
grep -q '"\[27\] ' "$m" && { echo "FAIL 出现多余的 [27]"; fail=1; }
grep -q '\[00\] 退出' "$m" || { echo "FAIL 缺少 [00]"; fail=1; }
while read -r script arg; do
  [[ -f scripts/$script ]] || { echo "FAIL 不存在 scripts/$script"; fail=1; continue; }
  [[ -z $arg ]] && continue
  grep -Eq "^[[:space:]]+([a-z0-9-]+ \| )?$arg\)" "scripts/$script" || { echo "FAIL $script 不支持子命令 $arg"; fail=1; }
done < <(sed -nE 's/.*\) run (vh-[a-z0-9]+\.sh) ?([a-z0-9-]*) ;;.*/\1 \2/p' "$m")
((fail == 0)) && echo "PASS menu"
exit $fail
