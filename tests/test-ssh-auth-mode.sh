#!/usr/bin/env bash
# 断言 SSH 登录方式识别覆盖密码、密钥、密码加 TOTP、密钥加 TOTP 与未限制配置
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VH_STATE="$T/state" VH_LOG=/dev/null SSHD_CONFIG="$T/sshd_config" SSHD_DROPIN="$T/00-vhm.conf" PAM_SSHD="$T/sshd.pam"
mkdir -p "$T"
cat >"$T/sshd" <<'SH'
#!/usr/bin/env bash
printf 'port 2222\npasswordauthentication %s\npubkeyauthentication %s\nkbdinteractiveauthentication %s\nauthenticationmethods %s\n' \
  "$FAKE_PASSWORD" "$FAKE_PUBKEY" "$FAKE_KBD" "$FAKE_METHOD"
SH
chmod +x "$T/sshd"
export SSHD_BIN="$T/sshd"
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
fail=0
check() {
  local expected=$1 method=$2 password=$3 pubkey=$4 kbd=$5 pam=$6
  export FAKE_METHOD=$method FAKE_PASSWORD=$password FAKE_PUBKEY=$pubkey FAKE_KBD=$kbd
  printf '%s\n' "$pam" >"$PAM_SSHD"
  local actual
  actual=$(ssh_auth_mode)
  [[ $actual == "$expected" ]] || { echo "FAIL expected=$expected actual=$actual"; fail=1; }
}
check password password yes no no '@include common-auth'
check key publickey no yes no '@include common-auth'
check password_totp keyboard-interactive no no yes $'@include common-auth\nauth required pam_google_authenticator.so'
check key_totp publickey,keyboard-interactive no yes yes $'#vhm# @include common-auth\nauth required pam_google_authenticator.so'
check key_password_totp publickey,keyboard-interactive no yes yes $'@include common-auth\nauth required pam_google_authenticator.so'
check totp_only keyboard-interactive no no yes 'auth required pam_google_authenticator.so'
check custom publickey,keyboard-interactive no yes yes $'#vhm# @include common-auth\nauth required pam_google_authenticator.so nullok'
check mixed any yes yes no '@include common-auth'
((fail == 0)) && echo "PASS ssh-auth-mode"
exit $fail
