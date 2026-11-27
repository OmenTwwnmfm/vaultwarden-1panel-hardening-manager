#!/usr/bin/env bash
# 断言大规则链下 ipt_has_line / ipt_find_id 不会因 grep 提前退出触发 SIGPIPE 而误判；
# ipt_find_id 按完整编号匹配，vhm:1 不会命中 vhm:12
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/iptables" <<'SH'
#!/usr/bin/env bash
seq 1 200000
echo '-A 1PANEL_BASIC -p tcp -m tcp --dport 12 -m comment --comment "vhm:12 备注" -j ACCEPT'
echo '-A 1PANEL_BASIC -p tcp -m tcp --dport 1 -m comment --comment vhm:1 -j ACCEPT'
echo '-A 1PANEL_BASIC -p tcp -m tcp --dport 8443 -m comment --comment "vhm:25112712000012345" -j ACCEPT'
SH
chmod +x "$T/bin/iptables"
export PATH="$T/bin:$PATH" VH_STATE="$T/state" VH_LOG=/dev/null
# shellcheck source=scripts/vh-firewall.sh
source scripts/vh-firewall.sh
fail=0
ipt_has_line ipv4 '-A 1PANEL_BASIC -p tcp -m tcp --dport 8443 -m comment --comment "vhm:25112712000012345" -j ACCEPT' ||
  { echo "FAIL 大输出下 ipt_has_line 误判为不存在"; fail=1; }
ipt_has_line ipv4 '-A 1PANEL_BASIC -p tcp --dport 9999 -j ACCEPT' && { echo "FAIL 不存在的规则被误判为存在"; fail=1; }
[[ $(ipt_find_id ipv4 25112712000012345) == *'--dport 8443 '* ]] || { echo "FAIL 大输出下 ipt_find_id 未找到规则"; fail=1; }
[[ $(ipt_find_id ipv4 1) == *'--dport 1 '* ]] || { echo "FAIL vhm:1 匹配到了其他规则：$(ipt_find_id ipv4 1)"; fail=1; }
[[ $(ipt_find_id ipv4 12) == *'--dport 12 '* ]] || { echo "FAIL vhm:12 未找到"; fail=1; }
[[ -z $(ipt_find_id ipv4 2511) ]] || { echo "FAIL 编号前缀被误匹配"; fail=1; }
((fail == 0)) && echo "PASS firewall-iptables"
exit $fail
