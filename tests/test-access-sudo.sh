#!/usr/bin/env bash
# 隔离验证普通管理员 sudo 的逐次密码 + TOTP、策略旁路拒绝与不自动扩权。
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export PAM_SUDO="$T/pam.d/sudo" PAM_SUDO_I="$T/pam.d/sudo-i" PAM_ACCESS_SUDO="$T/pam.d/vhm-access-sudo"
export PAM_COMMON_AUTH="$T/pam.d/common-auth" SUDOERS_MAIN="$T/sudoers" SUDOERS_DIR="$T/sudoers.d"
export SUDOERS_ACCESS="$T/sudoers.d/99-vhm-access" NSSWITCH_CONF="$T/nsswitch.conf" SUDO_CONF="$T/sudo.conf"
export ACCESS_PASSWD_FILE="$T/passwd"
# shellcheck source=scripts/lib/access-sudo.sh
source scripts/lib/access-sudo.sh
fail=0
fixture_uid=$(command id -u)
log_err() { printf '%s\n' "$*" >&2; }
_access_sudo_owner_uid() { printf '%s\n' "$fixture_uid"; }
_access_sudo_modules() { return 0; }
getent() { [[ $1 == passwd && $2 == admin ]] && cat "$ACCESS_PASSWD_FILE"; }
passwd() { printf 'admin %s 2026-11-28 0 99999 7 -1\n' "${FIXTURE_PASSWORD_STATUS:-P}"; }
id() {
  if [[ $1 == -nG && $2 == admin ]]; then printf '%s\n' "${FIXTURE_GROUPS:-admin sudo}"; else command id "$@"; fi
}
sudo() { printf "Sudoers path: %s\nAuthentication methods: '%s'\n" "$SUDOERS_MAIN" "${FIXTURE_AUTH_METHOD:-pam}"; }
visudo() {
  printf '%s\n' "$*" >>"$T/visudo-calls"
  [[ ${FIXTURE_VISUDO_FAIL:-0} == 0 ]] || return 1
  [[ ${FIXTURE_VISUDO_FAIL_AFTER_WRITE:-0} != 1 || ! -f $SUDOERS_ACCESS ]]
}
change_track() { printf '%s\n' "$1" >>"$T/tracked"; }

reset_fixture() {
  rm -rf -- "$T/pam.d" "$SUDOERS_DIR" "$T/private" "$SUDOERS_MAIN" "$T/extra" "$T/link" "$T/visudo-calls" "$T/tracked"
  mkdir -p "$T/pam.d" "$SUDOERS_DIR" "$T/private/admin" || exit 1
  chmod 700 "$T/private" "$T/private/admin" || exit 1
  printf 'admin:x:1000:1000:Administrator:/home/admin:/bin/bash\n' >"$ACCESS_PASSWD_FILE"
  printf 'passwd: files\ngroup: files\nsudoers: files\n' >"$NSSWITCH_CONF"
  printf '# default sudo plugins\n' >"$SUDO_CONF"
  cat >"$PAM_COMMON_AUTH" <<'EOF'
# Debian/Ubuntu common-auth
auth [success=1 default=ignore] pam_unix.so nullok
auth requisite pam_deny.so
auth required pam_permit.so
auth optional pam_cap.so
EOF
  cat >"$PAM_SUDO" <<'EOF'
#%PAM-1.0
session required pam_limits.so
@include common-auth
@include common-account
@include common-session-noninteractive
EOF
  cat >"$PAM_SUDO_I" <<'EOF'
#%PAM-1.0
auth include sudo
account include sudo
session include sudo
EOF
  printf 'Defaults env_reset\nDefaults mail_badpass\nDefaults secure_path="/usr/sbin:/usr/bin:/sbin:/bin"\nDefaults use_pty\nroot ALL=(ALL:ALL) ALL\n%%sudo ALL=(ALL:ALL) ALL\n@includedir %s\n' "$SUDOERS_DIR" >"$SUDOERS_MAIN"
  chmod 440 "$SUDOERS_MAIN"
  python3 - <<'PY' >"$T/private/admin/totp"
import base64
import secrets

print(base64.b32encode(secrets.token_bytes(20)).decode('ascii'))
print('" TOTP_AUTH')
PY
  chmod 600 "$T/private/admin/totp"
  unset FIXTURE_PASSWORD_STATUS FIXTURE_GROUPS FIXTURE_AUTH_METHOD FIXTURE_VISUDO_FAIL FIXTURE_VISUDO_FAIL_AFTER_WRITE
}

expect_refused() {
  local label=$1
  if access_sudo_preflight admin >"$T/output" 2>&1; then echo "FAIL $label"; fail=1; fi
  [[ ! -e $PAM_ACCESS_SUDO && ! -e $SUDOERS_ACCESS ]] || { echo "FAIL 预检拒绝时写入了配置"; fail=1; }
}

reset_fixture
access_sudo_preflight admin >"$T/output" 2>&1 || { echo "FAIL 标准本地管理员预检失败"; cat "$T/output"; fail=1; }
[[ ! -e $PAM_ACCESS_SUDO && ! -e $SUDOERS_ACCESS ]] || { echo "FAIL 只读预检创建了配置"; fail=1; }
access_sudo_track || exit 1
[[ $(wc -l <"$T/tracked") == 4 ]] || { echo "FAIL 未记录完整 sudo 配置"; fail=1; }
for path in "$PAM_SUDO" "$PAM_SUDO_I" "$PAM_ACCESS_SUDO" "$SUDOERS_ACCESS"; do
  grep -Fxq "$path" "$T/tracked" || { echo "FAIL 缺少备份路径：$path"; fail=1; }
done
cp "$SUDOERS_MAIN" "$T/sudoers-before"
cp "$PAM_COMMON_AUTH" "$T/common-auth-before"
access_sudo_apply admin "$T/private/admin/totp" >"$T/output" 2>&1 || { echo "FAIL sudo 策略应用失败"; cat "$T/output"; fail=1; }
grep -Fxq 'auth substack common-auth' "$PAM_ACCESS_SUDO" || { echo "FAIL 未将密码放在受限子栈内"; fail=1; }
grep -Fxq 'auth [success=1 auth_err=ignore ignore=ignore default=die] pam_succeed_if.so user != admin' "$PAM_ACCESS_SUDO" || { echo "FAIL 没有保持其他账号的密码认证与凭据阶段，或匹配错误未拒绝"; fail=1; }
grep -Fxq "auth required pam_google_authenticator.so user=root secret=$T/private/admin/totp" "$PAM_ACCESS_SUDO" || { echo "FAIL TOTP 没有使用 root 集中密钥"; fail=1; }
for path in "$PAM_SUDO" "$PAM_SUDO_I"; do
  grep -Fxq 'auth substack vhm-access-sudo' "$path" || { echo "FAIL sudo 或 sudo-i 没有进入认证子栈"; fail=1; }
done
grep -Fxq 'account include common-account' "$PAM_SUDO" || { echo "FAIL 未限定 common-account 的类型"; fail=1; }
grep -Fq 'authenticate, !rootpw, !targetpw, !runaspw, timestamp_timeout=0' "$SUDOERS_ACCESS" || { echo "FAIL 没有关闭认证缓存或强制当前账号密码"; fail=1; }
grep -Fq 'pam_service="sudo", pam_login_service="sudo-i", listpw=always, verifypw=always' "$SUDOERS_ACCESS" || { echo "FAIL 没有限定 PAM 服务和验证行为"; fail=1; }
grep -Eq '^admin[[:space:]].*ALL' "$SUDOERS_ACCESS" && { echo "FAIL 不应自动添加 ALL 授权"; fail=1; }
grep -Eq 'nullok|no_strict_owner|forward_pass' "$PAM_ACCESS_SUDO" && { echo "FAIL 托管 TOTP 存在旁路选项"; fail=1; }
[[ $(stat -c '%a' "$SUDOERS_ACCESS") == 440 ]] || { echo "FAIL sudoers 权限错误"; fail=1; }
cmp -s "$SUDOERS_MAIN" "$T/sudoers-before" && cmp -s "$PAM_COMMON_AUTH" "$T/common-auth-before" || { echo "FAIL 改写了原授权或全局密码栈"; fail=1; }
[[ $(wc -l <"$T/visudo-calls") -ge 3 ]] || { echo "FAIL 未检查完整 sudoers"; fail=1; }
access_sudo_apply admin "$T/private/admin/totp" >"$T/output" 2>&1 || { echo "FAIL 重复应用不幂等"; cat "$T/output"; fail=1; }
access_sudo_verify admin "$T/private/admin/totp" >"$T/output" 2>&1 || { echo "FAIL 无法只读确认已生效的托管策略"; cat "$T/output"; fail=1; }
cp "$PAM_SUDO_I" "$T/sudo-i-before"
printf '@include common-auth\n@include common-account\n@include common-session\n' >"$PAM_SUDO_I"
access_sudo_verify admin "$T/private/admin/totp" >"$T/output" 2>&1 && { echo "FAIL 只读校验没有发现 sudo-i 改回密码认证"; fail=1; }
mv -f "$T/sudo-i-before" "$PAM_SUDO_I"
access_sudo_verify admin "$T/private/admin/totp-other" >"$T/output" 2>&1 && { echo "FAIL 接受了与托管策略不匹配的密钥"; fail=1; }

reset_fixture
rm -f "$PAM_SUDO_I"
access_sudo_apply admin "$T/private/admin/totp" >"$T/output" 2>&1 || { echo "FAIL sudo-i 缺失时没有建立认证入口"; cat "$T/output"; fail=1; }
grep -Fxq 'auth substack vhm-access-sudo' "$PAM_SUDO_I" || { echo "FAIL sudo-i fallback 没有显式认证"; fail=1; }

for rule in 'admin ALL=(ALL) NOPASSWD: ALL' 'Defaults !authenticate' 'Defaults exempt_group=sudo' \
  'Defaults rootpw' 'Defaults timestamp_timeout=5' 'Defaults pam_service=other' 'Defaults pam_login_service=other' \
  'Defaults listpw=never' 'Defaults verifypw=never' 'Defaults:admin timestamp_timeout=0' \
  'Cmnd_Alias SOME = /usr/bin/id' 'admin ALL=(ALL) PASSWD: /usr/bin/id' 'admin ALL=(ALL) !/usr/bin/id'; do
  reset_fixture
  printf '%s\n' "$rule" >"$SUDOERS_DIR/10-custom"
  expect_refused "允许了无法证明安全的策略：$rule"
done

reset_fixture
FIXTURE_GROUPS='admin'
expect_refused '自动给非管理员扩权'
printf 'admin ALL=(ALL) PASSWD: ALL\n' >"$SUDOERS_DIR/20-admin"
access_sudo_preflight admin >"$T/output" 2>&1 || { echo "FAIL 显式的用户 PASSWD:ALL 授权未通过"; cat "$T/output"; fail=1; }

for config in 'sudoers: files sss' 'sudoers: ldap'; do
  reset_fixture
  printf '%s\n' "$config" >>"$NSSWITCH_CONF"
  expect_refused "允许了外部策略源：$config"
done
reset_fixture
printf 'Plugin custom_policy other.so\n' >"$SUDO_CONF"
expect_refused '允许了自定义策略插件'
reset_fixture
printf 'auth sufficient pam_permit.so\n' >>"$PAM_SUDO"
expect_refused '允许了 sudo PAM 认证旁路'
reset_fixture
printf 'auth sufficient pam_permit.so\n' >>"$PAM_COMMON_AUTH"
expect_refused '允许了自定义 common-auth 密码旁路'
reset_fixture
printf 'auth sufficient pam_permit.so\n' >>"$PAM_SUDO_I"
expect_refused '允许了 sudo-i PAM 认证旁路'
reset_fixture
printf 'admin ALL=(ALL) NOPASSWD: ALL\n' >"$T/extra"
printf '@include %s\n' "$T/extra" >"$SUDOERS_DIR/10-nested"
expect_refused '没有审核递归 include'
reset_fixture
printf '@include %s\n' "$SUDOERS_MAIN" >"$SUDOERS_DIR/10-cycle"
expect_refused '允许了 include 循环'
reset_fixture
printf 'admin ALL=(ALL) NOPASSWD: \\\nALL\n' >"$SUDOERS_DIR/10-continuation"
expect_refused '续行隐藏了 NOPASSWD'
reset_fixture
printf '# comment \\\nadmin ALL=(ALL) NOPASSWD: ALL\n' >"$SUDOERS_DIR/10-comment-continuation"
expect_refused '注释续行隐藏了活动授权规则'
reset_fixture
FIXTURE_PASSWORD_STATUS=L
expect_refused '接受了锁定密码'
reset_fixture
FIXTURE_PASSWORD_STATUS=NP
expect_refused '接受了空密码'
reset_fixture
FIXTURE_AUTH_METHOD=passwd
expect_refused '接受了未使用 PAM 的 sudo'
reset_fixture
FIXTURE_VISUDO_FAIL=1
expect_refused '忽略了现有 sudoers 语法错误'

for invalid in public executable link hardlink parent traversal; do
  reset_fixture
  secret="$T/private/admin/totp"
  case $invalid in
    public) chmod 644 "$secret" ;;
    executable) chmod 700 "$secret" ;;
    link) ln -s "$secret" "$T/link"; secret="$T/link" ;;
    hardlink) ln "$secret" "$T/link" ;;
    parent) chmod 755 "$T/private/admin" ;;
    traversal) secret="$T/private/admin/../admin/totp" ;;
  esac
  access_sudo_apply admin "$secret" >"$T/output" 2>&1 && { echo "FAIL 接受了不安全的集中密钥：$invalid"; fail=1; }
  [[ ! -e $PAM_ACCESS_SUDO && ! -e $SUDOERS_ACCESS ]] || { echo "FAIL 密钥拒绝前写入了配置"; fail=1; }
done
reset_fixture
FIXTURE_VISUDO_FAIL_AFTER_WRITE=1
access_sudo_apply admin "$T/private/admin/totp" >"$T/output" 2>&1 && { echo "FAIL 忽略了修改后完整 sudoers 验证错误"; fail=1; }

((fail == 0)) && echo 'PASS access-sudo'
exit "$fail"
