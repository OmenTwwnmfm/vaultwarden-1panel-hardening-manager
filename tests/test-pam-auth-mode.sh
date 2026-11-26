#!/usr/bin/env bash
# 断言 PAM 登录方式切换能恢复 @include 与 auth substack 两种 common-auth 写法
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VH_STATE="$T/state" VH_LOG=/dev/null PAM_SSHD="$T/sshd"
# shellcheck source=scripts/vh-ssh.sh
source scripts/vh-ssh.sh
fail=0

cat >"$PAM_SSHD" <<'EOF'
auth required pam_env.so
#vhm# auth substack common-auth
auth required pam_google_authenticator.so
@include common-account
EOF
pam_set_auth_mode key || { echo "FAIL 切换到密钥登录失败"; fail=1; }
grep -Fxq 'auth substack common-auth' "$PAM_SSHD" || { echo "FAIL substack common-auth 未取消注释"; fail=1; }
grep -q 'pam_google_authenticator' "$PAM_SSHD" && { echo "FAIL 动态口令行未移除"; fail=1; }

cat >"$PAM_SSHD" <<'EOF'
auth required pam_env.so
@include common-auth
@include common-account
EOF
pam_set_auth_mode key_totp || { echo "FAIL 切换到密钥 + 动态口令失败"; fail=1; }
grep -Fxq '#vhm# @include common-auth' "$PAM_SSHD" || { echo "FAIL @include common-auth 未注释"; fail=1; }
grep -Fxq 'auth required pam_google_authenticator.so' "$PAM_SSHD" || { echo "FAIL 动态口令行未添加"; fail=1; }

pam_set_auth_mode password_totp || { echo "FAIL 切换到密码 + 动态口令失败"; fail=1; }
grep -Fxq '@include common-auth' "$PAM_SSHD" || { echo "FAIL 密码 + 动态口令未恢复 common-auth"; fail=1; }
common_line=$(grep -n '^@include common-auth$' "$PAM_SSHD" | cut -d: -f1)
totp_line=$(grep -n '^auth required pam_google_authenticator\.so$' "$PAM_SSHD" | cut -d: -f1)
[[ -n $common_line && -n $totp_line && $common_line -lt $totp_line ]] ||
  { echo "FAIL 密码 + 动态口令的 PAM 顺序不对"; fail=1; }

pam_set_auth_mode key || { echo "FAIL 从密码 + 动态口令切回密钥失败"; fail=1; }
grep -Fxq '@include common-auth' "$PAM_SSHD" || { echo "FAIL 切回密钥后 common-auth 未恢复"; fail=1; }
grep -q 'pam_google_authenticator' "$PAM_SSHD" && { echo "FAIL 切回密钥后仍有动态口令行"; fail=1; }

((fail == 0)) && echo "PASS pam-auth-mode"
exit $fail
