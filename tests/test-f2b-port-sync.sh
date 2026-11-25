#!/usr/bin/env bash
# 断言 sshd 端口变化后 Fail2Ban sshd jail 自动同步且重复检查不会重复记录
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export PATH="$T/bin:$PATH" VH_STATE="$T/state" VH_LOG=/dev/null VH_LOCK="$T/lock" F2B_JAIL="$T/sshd.local"
cat >"$T/bin/fail2ban-client" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$T/bin/fail2ban-client"
cat >"$F2B_JAIL" <<'EOF'
[sshd]
enabled = true
port = 22
backend = systemd
maxretry = 5
EOF
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
sshd_eff() { printf 'port %s\n' "$FAKE_SSH_PORT"; }
f2b_reload() { return 0; }
fail=0
FAKE_SSH_PORT=10098
f2b_sync_ssh_port || fail=1
grep -Fxq 'port = 10098' "$F2B_JAIL" || { echo "FAIL 第一次端口变更未同步"; fail=1; }
before=$(find "$VH_CHANGES" -mindepth 1 -maxdepth 1 -type d | wc -l)
f2b_sync_ssh_port || fail=1
after=$(find "$VH_CHANGES" -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ $before == "$after" ]] || { echo "FAIL 重复检查创建了额外记录"; fail=1; }
FAKE_SSH_PORT=2222
f2b_sync_ssh_port || fail=1
grep -Fxq 'port = 2222' "$F2B_JAIL" || { echo "FAIL 第二次端口变更未同步"; fail=1; }
((fail == 0)) && echo "PASS f2b-port-sync"
exit $fail
