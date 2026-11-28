#!/usr/bin/env bash
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export VH_LOG=/dev/null
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
mkdir -m 755 "$T/shared" || exit 1
fail=0

kv_set "$T/shared/hardening.conf" AUTO_UPDATE notify || { echo "FAIL 配置写入失败"; fail=1; }
[[ $(stat -c %a "$T/shared") == 755 ]] || { echo "FAIL 改动了共享目录权限"; fail=1; }
[[ $(stat -c %a "$T/shared/hardening.conf") == 600 ]] || { echo "FAIL 配置文件权限不是 600"; fail=1; }
kv_set "$T/private/hardening.conf" AUTO_UPDATE off || { echo "FAIL 创建配置目录失败"; fail=1; }
[[ $(stat -c %a "$T/private") == 700 ]] || { echo "FAIL 新建配置目录权限不是 700"; fail=1; }

sysctl() {
  printf '%s\n' "$3" >>"$T/restore.log"
  [[ $3 != net.ipv4.tcp_syncookies=0 ]]
}
printf '%s\n' net.ipv4.tcp_syncookies=0 net.ipv4.icmp_echo_ignore_broadcasts=1 >"$T/sysctl.prev"
sysctl_restore "$T" && { echo "FAIL 忽略了较早的参数恢复失败"; fail=1; }
grep -Fxq net.ipv4.icmp_echo_ignore_broadcasts=1 "$T/restore.log" || { echo "FAIL 单项失败后未继续恢复"; fail=1; }

((fail == 0)) && echo "PASS system-config"
exit "$fail"
