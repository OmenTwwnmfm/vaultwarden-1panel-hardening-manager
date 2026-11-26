#!/usr/bin/env bash
# 断言 UFW 删除只按 vhm 注释定位，同条件但非 vhm 的规则保持不动
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export VH_STATE="$T/state" VH_LOG=/dev/null FAKE_UFW_STATE="$T/status" FAKE_UFW_LOG="$T/deleted"
cat >"$T/bin/ufw" <<'SH'
#!/usr/bin/env bash
case ${1:-} in
  status)
    if [[ ${2:-} == numbered ]]; then
      printf '%s:%s\n' "$LC_ALL" "$LANGUAGE" >>"$FAKE_UFW_LOG"
      cat "$FAKE_UFW_STATE"
    fi
    ;;
  --force)
    [[ ${2:-} == delete && ${3:-} =~ ^[0-9]+$ ]] || exit 1
    printf '%s\n' "$3" >>"$FAKE_UFW_LOG"
    awk -v n="$3" '
      {
        if (match($0, /^\[ *[0-9]+\]/)) {
          num = substr($0, RSTART + 1, RLENGTH - 2)
          gsub(/[^0-9]/, "", num)
          if (num + 0 == n + 0) next
        }
        print
      }' "$FAKE_UFW_STATE" >"$FAKE_UFW_STATE.tmp" && mv -f "$FAKE_UFW_STATE.tmp" "$FAKE_UFW_STATE"
    ;;
  *)
    echo "Skipping adding existing rule"
    ;;
esac
SH
chmod +x "$T/bin/ufw"
export PATH="$T/bin:$PATH"
cat >"$FAKE_UFW_STATE" <<'EOF'
[ 1] 22/tcp                     ALLOW IN    Anywhere                   # 1Panel SSH
[ 2] 8443/tcp                   ALLOW IN    Anywhere                   # vhm:25112712000012345 测试
[ 3] 8443/tcp (v6)              ALLOW IN    Anywhere (v6)              # vhm:25112712000012345 测试
[ 4] 9000/tcp                   ALLOW IN    Anywhere                   # 1Panel app
EOF
# shellcheck source=scripts/vh-firewall.sh
source scripts/vh-firewall.sh
fail=0
mapfile -t nums < <(ufw_comment_numbers 25112712000012345 | sort -n)
[[ ${nums[*]} == "2 3" ]] || { echo "FAIL 标记编号识别错误：${nums[*]}"; fail=1; }
grep -qx 'C:en_US:en' "$FAKE_UFW_LOG" || { echo "FAIL UFW 调用未固定英文 locale"; fail=1; }
ufw_del_comment 25112712000012345 || { echo "FAIL 按标记删除失败"; fail=1; }
grep -q 'vhm:25112712000012345' "$FAKE_UFW_STATE" && { echo "FAIL 标记规则未删除"; fail=1; }
grep -q '1Panel SSH' "$FAKE_UFW_STATE" || { echo "FAIL 误删了同条件的非 vhm 规则"; fail=1; }
grep -q '1Panel app' "$FAKE_UFW_STATE" || { echo "FAIL 误删了其他规则"; fail=1; }
ufw_del_comment 25112712000012345 || { echo "FAIL 已删除时不应报错"; fail=1; }
ufw_del_comment 25112712000012345 1 && { echo "FAIL 要求必须存在时却返回成功"; fail=1; }
ufw_add allow tcp 22 any 0 "vhm:25112712000099999 测试" && { echo "FAIL 同条件的非 vhm 规则应拒绝添加"; fail=1; }
((fail == 0)) && echo "PASS ufw-marker"
exit $fail
