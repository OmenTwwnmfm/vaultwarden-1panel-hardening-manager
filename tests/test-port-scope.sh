#!/usr/bin/env bash
# 断言端口体检按 BEFORE → BASIC → AFTER 顺序判断，并忽略 loopback / ESTABLISHED
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/iptables" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-w -S INPUT") echo '-A INPUT -j 1PANEL_BASIC' ;;
  *1PANEL_BASIC_BEFORE)
    cat <<'EOF'
-A 1PANEL_BASIC_BEFORE -p tcp -m tcp --dport 10098 -j ACCEPT
-A 1PANEL_BASIC_BEFORE -i lo -j ACCEPT
-A 1PANEL_BASIC_BEFORE -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
EOF
    ;;
  *1PANEL_BASIC_AFTER)
    cat <<'EOF'
-A 1PANEL_BASIC_AFTER -p tcp -j DROP
-A 1PANEL_BASIC_AFTER -p udp -j DROP
EOF
    ;;
  *1PANEL_BASIC)
    cat <<'EOF'
-A 1PANEL_BASIC -p tcp -m multiport --dports 8443,8444 -s 1.2.3.0/24 -j ACCEPT
-A 1PANEL_BASIC -p tcp -m conntrack --ctstate NEW --dport 9443 -s 10.0.0.0/8 -j ACCEPT
-A 1PANEL_BASIC -p tcp --dport 9000 -j DROP
EOF
    ;;
esac
SH
chmod +x "$T/bin/iptables"
export PATH="$T/bin:$PATH" VH_STATE="$T/state" VH_LOG=/dev/null
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
fail=0
expect() {
  local want=$1 port=$2 proto=$3 got
  got=$(port_scope "$port" "$proto")
  [[ $got == "$want" ]] || { echo "FAIL $port/$proto expected=$want actual=$got"; fail=1; }
}
expect all 10098 tcp
expect limited 8443 tcp
expect limited 8444 tcp
expect limited 9443 tcp
expect none 10099 tcp
expect none 22 tcp
expect none 9000 tcp
expect none 10098 udp
((fail == 0)) && echo "PASS port-scope"
exit $fail
