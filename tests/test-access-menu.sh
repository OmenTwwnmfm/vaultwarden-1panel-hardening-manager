#!/usr/bin/env bash
# 实际读取 [06] 用户类型/用户名/模式输入；配置写入与系统账户操作由隔离 mock 记录。
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
test_dir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$test_dir"' EXIT
export VH_LOG=/dev/null VH_STATE="$test_dir/state" VH_CONF="$test_dir/config" VH_LOCK="$test_dir/lock"
# shellcheck source=scripts/vh-access.sh
source scripts/vh-access.sh

fail() { echo "FAIL $*" >&2; exit 1; }
trace="$test_dir/trace"
title() { printf '%s\n' "$*"; }
access_set_user() {
  [[ $1 == fixtureuser ]] || return 1
  ACCESS_USER=$1 ACCESS_UID=12345
  ACCESS_KEY_FILE="$test_dir/key" ACCESS_GA_FILE="$test_dir/totp"
}

# 已启用的强管理员方案不能被四种普通方式降级，root 也不能通过此入口重开。
access_active() { return 0; }
access_user() { printf 'fixtureuser\n'; }
access_profile_preflight() { printf 'preflight\n' >>"$trace"; return 1; }
change_begin() { printf 'change\n' >>"$trace"; return 1; }
dropin_set() { printf 'global-write\n' >>"$trace"; return 1; }
for user in root fixtureuser; do
  for mode in password key password_totp key_totp; do
    : >"$trace"
    access_profile_configure "$user" "$mode" >"$test_dir/output" 2>&1 && fail "active scheme allowed $user $mode"
    [[ ! -s $trace ]] || fail 'active scheme reached preflight or configuration writes'
  done
done

# 保留真正的 access_choose_user，验证菜单输入确实传递选定用户而不是旧的全局 root 配置。
access_profile_get() { return 1; }
access_profile_configure() { printf 'profile\t%s\t%s\n' "$1" "$2" >>"$trace"; }
access_setup() { printf 'advanced\t%s\n' "${1:-missing}" >>"$trace"; }
configure_auth_mode() { printf 'legacy-global\n' >>"$trace"; return 1; }
for choice in 1 2 3 4; do
  case $choice in 1) mode=password ;; 2) mode=key ;; 3) mode=password_totp ;; 4) mode=key_totp ;; esac
  : >"$trace"
  access_auth_menu <<<"$(printf '1\n%s\n' "$choice")" >"$test_dir/output" 2>&1 || fail 'root menu returned failure'
  [[ $(<"$trace") == $'profile\troot\t'"$mode" ]] || fail "root mode $choice did not dispatch correctly"
  grep -Fq '[6]' "$test_dir/output" && fail 'root menu offered ordinary administrator migration'
  : >"$trace"
  access_auth_menu <<<"$(printf '2\nfixtureuser\n%s\n' "$choice")" >"$test_dir/output" 2>&1 || fail 'ordinary-user menu returned failure'
  [[ $(<"$trace") == $'profile\tfixtureuser\t'"$mode" ]] || fail "ordinary-user mode $choice did not dispatch correctly"
  grep -Fq '[6]' "$test_dir/output" || fail 'ordinary-user menu omitted administrator migration'
done

: >"$trace"
access_auth_menu <<<'2
fixtureuser
6' >"$test_dir/output" 2>&1 || fail 'advanced option returned failure'
[[ $(<"$trace") == $'advanced\tfixtureuser' ]] || fail 'advanced option discarded the selected username'

: >"$trace"
access_auth_menu <<<'1
6' >"$test_dir/output" 2>&1 || true
[[ ! -s $trace ]] || fail 'unadvertised root option launched ordinary-user setup'
grep -Fq '[6]' "$test_dir/output" && fail 'root menu advertised the advanced option'

: >"$trace"
access_auth_menu <<<'2
missinguser
1' >"$test_dir/output" 2>&1 || true
[[ ! -s $trace ]] || fail 'an unknown user reached configuration'
access_auth_menu <<<'0' >"$test_dir/output" 2>&1 || true
[[ ! -s $trace ]] || fail 'canceling user selection changed configuration'

echo 'PASS access-menu'
