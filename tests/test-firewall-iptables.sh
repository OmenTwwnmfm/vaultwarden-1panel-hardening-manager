#!/usr/bin/env bash
# 断言大规则链下 ipt_has_line 不会因 grep -q 提前退出触发 SIGPIPE 而误判
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/iptables" <<'SH'
#!/usr/bin/env bash
seq 1 200000
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
((fail == 0)) && echo "PASS firewall-iptables"
exit $fail
