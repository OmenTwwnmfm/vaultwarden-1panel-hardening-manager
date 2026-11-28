#!/usr/bin/env bash
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d) || exit 1
trap 'rm -f -- "$T/access.conf" "$T/sshd.pam" "$T/sshd"; rmdir -- "$T"' EXIT
export VH_STATE="$T" ACCESS_STATE="$T/access.conf" VH_LOG=/dev/null
export ACCESS_PROFILES_STATE="$T/ssh-profiles.json" PAM_SSHD="$T/sshd.pam"
export ACCESS_SECRETS_DIR="$T/secrets" SSHD_CONFIG="$T/sshd_config" SSHD_DROPIN="$T/00-vhm.conf"
export ROOT_KEYS="$T/root-keys" GA_FILE="$T/root-totp" SSHD_BIN="$T/sshd"
export SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 2222'
printf 'ACCESS_USER="admin"\n' >"$ACCESS_STATE"
printf 'auth required pam_google_authenticator.so\n' >"$PAM_SSHD"
cat >"$SSHD_BIN" <<'SH'
#!/usr/bin/env bash
case ${3:-} in
  user=root,*laddr=192.0.2.20,lport=2222)
    [[ $FIXTURE_ROOT != unknown ]] || exit 1
    printf 'PermitRootLogin %s\nPasswordAuthentication yes\nAuthenticationMethods any\n' "$FIXTURE_ROOT"
    ;;
  user=admin,*)
    printf 'PermitRootLogin yes\nPasswordAuthentication no\nAuthenticationMethods publickey,keyboard-interactive:pam\n'
    ;;
  *) exit 1 ;;
esac
printf 'Port 2222\nPubkeyAuthentication yes\nKbdInteractiveAuthentication yes\nUsePAM yes\n'
SH
chmod +x "$SSHD_BIN"
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

health=$(FIXTURE_ROOT=no bash scripts/vh-checkup.sh ssh) || fail 'SSH 体检失败'
status=$(FIXTURE_ROOT=no bash scripts/vh-ssh.sh status) || fail 'SSH 状态失败'
grep -Fq '[正常] root 直接登录：已禁止' <<<"$health" || fail '体检使用了管理员上下文的 PermitRootLogin'
grep -Eq 'root 登录许可[[:space:]]+no$' <<<"$status" || fail 'SSH 状态使用了管理员上下文的 PermitRootLogin'
grep -Fq 'admin 的 SSH 2FA：已启用' <<<"$health" || fail '体检未区分普通管理员的 TOTP'
grep -Eq '认证账号[[:space:]]+admin$' <<<"$status" || fail 'SSH 状态未注明认证方式对应的账号'

health=$(FIXTURE_ROOT=yes bash scripts/vh-checkup.sh ssh) || fail 'SSH 体检失败'
grep -Fq '[危险] root 直接登录：允许 root 用密码登录' <<<"$health" || fail '体检将普通管理员的 TOTP 套用于仍允许密码登录的 root'

health=$(FIXTURE_ROOT=unknown bash scripts/vh-checkup.sh ssh) || fail 'SSH 体检失败'
status=$(FIXTURE_ROOT=unknown bash scripts/vh-ssh.sh status) || fail 'SSH 状态失败'
grep -Fq '[注意] root 直接登录：无法读取 root 的生效配置' <<<"$health" || fail '体检用其他账号的配置推断未知的 root 状态'
grep -Eq 'root 登录许可[[:space:]]+未知' <<<"$status" || fail 'SSH 状态用其他账号的配置推断未知的 root 状态'

echo 'PASS ssh-status-context'
