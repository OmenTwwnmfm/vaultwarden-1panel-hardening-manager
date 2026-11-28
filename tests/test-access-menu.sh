#!/usr/bin/env bash
# 实际读取 [06] 用户类型/用户名/模式输入；配置写入与系统账户操作由隔离 mock 记录。
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
test_dir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$test_dir"' EXIT
export VH_LOG=/dev/null VH_STATE="$test_dir/state" VH_CONF="$test_dir/config" VH_LOCK="$test_dir/lock"
export ACCESS_PASSWD_FILE="$test_dir/passwd" ACCESS_SHELLS_FILE="$test_dir/shells"
printf '%s\n' 'fixtureuser:x:12345:12345::/home/fixtureuser:/bin/bash' \
  'systemuser:x:100:100::/nonexistent:/bin/false' >"$ACCESS_PASSWD_FILE"
printf '/bin/bash\n' >"$ACCESS_SHELLS_FILE"
# shellcheck source=scripts/vh-access.sh
source scripts/vh-access.sh

fail() { echo "FAIL $*" >&2; exit 1; }
trace="$test_dir/trace"
title() { printf '%s\n' "$*"; }
getent() {
  [[ $1 == passwd && $# == 2 ]] || fail 'unexpected getent invocation'
  case $2 in
    remoteuser) printf 'remoteuser:x:12401:12401::/home/remoteuser:/bin/bash\n' ;;
    nssfailure) return 3 ;;
    *) awk -F: -v name="$2" '$1 == name { print; found=1 } END { if (!found) exit 2 }' "$ACCESS_PASSWD_FILE" ;;
  esac
}
sudo() { [[ $* == "-n -l -U ${fixture_sudo_user:-none}" ]]; }
access_password_terminal() { [[ ${fixture_terminal:-1} == 1 ]]; }
access_safe_path() { [[ $1 == /home/* ]]; }
useradd() {
  local user=${@: -1}
  [[ $* == "--create-home --home-dir /home/$user --user-group --shell /bin/bash -- $user" ]] || fail 'account was not created with a private group and no extra privileges'
  printf 'useradd\t%s\n' "$user" >>"$trace"
  [[ $user != failedadd ]] || return 1
  printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$user" "$fixture_uid" "$fixture_uid" "$user" >>"$ACCESS_PASSWD_FILE"
}
id() {
  case $1 in
    -g) printf '%s\n' "$fixture_uid" ;;
    -gn) printf '%s\n' "$2" ;;
    -G) printf '%s\n' "${fixture_groups:-$fixture_uid}" ;;
    *) fail 'unexpected id invocation' ;;
  esac
}
passwd() {
  if [[ $1 == -S ]]; then
    [[ -f $test_dir/password-ok-$2 ]] || return 1
    printf '%s P 2026-11-28 0 99999 7 -1\n' "$2"
    return
  fi
  [[ $# == 1 ]] || fail 'a noninteractive password or unsupported option was passed'
  printf 'passwd\t%s\n' "$1" >>"$trace"
  printf 'fixture native password prompt\n'
  [[ $1 != failedpass ]] || return 1
  : >"$test_dir/password-ok-$1"
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
access_active() { return 1; }
ga_install() { printf 'ga-install\n' >>"$trace"; return 1; }
: >"$trace"
access_auth_menu <<<'2
fixtureuser
6' >"$test_dir/output" 2>&1 && fail 'advanced migration accepted an account without sudo'
grep -Fq '只配置 SSH 请使用 [06] 的 [1]–[4]' "$test_dir/output" || fail 'advanced migration did not explain how to proceed without sudo'
[[ ! -s $trace ]] || fail 'advanced migration changed anything before verifying sudo'

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
export VH_ASSUME_YES=1
access_auth_menu <<<'2
missinguser
no' >"$test_dir/output" 2>&1 || fail 'declining creation failed'
grep -Fq '本机普通用户：fixtureuser' "$test_dir/output" || fail 'existing ordinary users were not listed'
grep -Fq '未找到用户 missinguser' "$test_dir/output" || fail 'missing account was not explained'
grep -Fq '单独配置前，该账号沿用现有默认 SSH 规则' "$test_dir/output" || fail 'account creation did not explain inherited login rules'
[[ ! -s $trace ]] || fail 'declining creation changed an account or configuration'
printf '2\nmissinguser\n' | access_auth_menu >"$test_dir/output" 2>&1 || fail 'EOF did not cancel user creation'
[[ ! -s $trace ]] || fail 'EOF created an account when generic confirmation bypass was set'
access_auth_menu <<<'0' >"$test_dir/output" 2>&1 || true
[[ ! -s $trace ]] || fail 'canceling user selection changed configuration'

for user in root '../invalid' systemuser remoteuser nssfailure; do
  access_auth_menu <<<"$(printf '2\n%s\nyes\n2\n' "$user")" >"$test_dir/output" 2>&1 || fail 'invalid selection did not return to menu'
  [[ ! -s $trace ]] || fail "ineligible identity reached user creation: $user"
  grep -Eq '用户名须|普通用户|本地账号|账户数据库' "$test_dir/output" || fail "ineligible identity did not explain rejection: $user"
done

access_profile_tfa_menu <<<'2
missinguser
yes' >"$test_dir/output" 2>&1 || fail 'missing user in [07] did not return to menu'
grep -Fq '此处只选择已有用户；可到 [06] 创建普通用户' "$test_dir/output" || fail '[07] did not explain how to handle a missing account'
[[ ! -s $trace ]] || fail '[07] created an account or changed configuration'

fixture_uid=12402
fixture_terminal=0
access_auth_menu <<<'2
missinguser
yes' >"$test_dir/output" 2>&1 || fail 'noninteractive creation did not return to menu'
grep -Fq '创建用户需要交互终端' "$test_dir/output" || fail 'noninteractive creation was not explained'
[[ ! -s $trace ]] || fail 'noninteractive creation reached system account operations'
fixture_terminal=1

access_auth_menu <<<'2
createduser
yes
0' >"$test_dir/output" 2>&1 || fail 'confirmed account creation failed'
grep -Fq 'fixture native password prompt' "$test_dir/output" || fail 'native password prompt was hidden by username capture'
grep -Fq 'createduser 的 SSH 登录方式' "$test_dir/output" || fail 'the created account did not reach its SSH menu'
[[ $(<"$trace") == $'useradd\tcreateduser\npasswd\tcreateduser' ]] || fail 'creation without a mode selection modified SSH or skipped setting a password'

: >"$trace"
fixture_uid=12403
access_auth_menu <<<'2
seconduser
yes
2' >"$test_dir/output" 2>&1 || fail 'new account could not choose SSH mode'
[[ $(<"$trace") == $'useradd\tseconduser\npasswd\tseconduser\nprofile\tseconduser\tkey' ]] || fail 'created account SSH mode was not applied to the selected account'

: >"$trace"
fixture_uid=12404
access_auth_menu <<<'2
failedpass
yes
2' >"$test_dir/output" 2>&1 || fail 'password error did not return to menu'
[[ $(<"$trace") == $'useradd\tfailedpass\npasswd\tfailedpass' && ! -e $test_dir/password-ok-failedpass ]] || fail 'failure to set password reached SSH configuration'
grep -Fq '已创建，但未确认可用密码' "$test_dir/output" || fail 'password failure did not explain the remaining account'

: >"$trace"
fixture_uid=12405 fixture_sudo_user=alloweduser
access_auth_menu <<<'2
alloweduser
yes
2' >"$test_dir/output" 2>&1 || fail 'existing sudo rule did not return to menu'
[[ $(<"$trace") == $'useradd\talloweduser' ]] || fail 'created a usable account matched by an existing sudo rule'
grep -Fq '现有 sudo 规则允许该用户使用 sudo' "$test_dir/output" || fail 'implicit sudo permission was not explained'

: >"$trace"
fixture_uid=12406
access_auth_menu <<<'2
failedadd
yes
2' >"$test_dir/output" 2>&1 || fail 'useradd error did not return to menu'
[[ $(<"$trace") == $'useradd\tfailedadd' ]] || fail 'useradd failure reached password or SSH configuration'
grep -Fq '系统未确认创建 failedadd 成功' "$test_dir/output" || fail 'useradd failure reported an inaccurate result'

echo 'PASS access-menu'
