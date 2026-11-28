#!/usr/bin/env bash
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
test_dir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$test_dir"' EXIT
chmod 755 "$test_dir"
export VH_LOG=/dev/null VH_STATE="$test_dir/state" VH_CONF="$test_dir/config" VH_LOCK="$test_dir/lock"
# shellcheck source=scripts/vh-access.sh
source scripts/vh-access.sh

fail() { echo "FAIL $*" >&2; exit 1; }
_access_profile_modules() { return 0; }
_access_profile_owner_uid() { id -u; }

access_set_user() {
  [[ $1 == fixtureuser ]] || return 1
  ACCESS_USER=$1 ACCESS_UID=12345
  ACCESS_KEY_FILE="$ACCESS_KEYS_DIR/$1" ACCESS_GA_FILE="$ACCESS_SECRETS_DIR/$1/totp"
}

fixture() {
  work="$test_dir/$1"
  mkdir -p "$work/sshd_config.d" "$work/pam" "$work/keys" "$work/secrets/fixtureuser" || fail 'fixture directory'
  SSHD_CONFIG="$work/sshd_config" SSHD_DROPIN="$work/sshd_config.d/00-vhm.conf"
  PAM_SSHD="$work/pam/sshd" PAM_ACCESS_SSH="$work/pam/vhm-access-ssh" PAM_ACCESS_LEGACY="$work/pam/vhm-access-ssh-legacy"
  PAM_COMMON_AUTH="$work/pam/common-auth" PAM_PROFILE_PREFIX="$work/pam/vhm-ssh-user-"
  ACCESS_PROFILES_STATE="$work/state/profiles.json"
  ACCESS_KEYS_DIR="$work/keys" ACCESS_SECRETS_DIR="$work/secrets"
  VH_STATE="$work/state" VH_CHANGES="$work/state/changes" VH_LOCK="$work/lock" ACCESS_STATE="$work/state/access.conf"
  chmod 755 "$work" "$work/keys" "$work/pam" "$work/sshd_config.d"
  chmod 700 "$work/secrets" "$work/secrets/fixtureuser"
  printf 'Include %s/*.conf\nUsePAM yes\nPort 2222\nSubsystem sftp internal-sftp\n' "$work/sshd_config.d" >"$SSHD_CONFIG"
  printf 'PermitRootLogin yes\nPasswordAuthentication no\nPubkeyAuthentication yes\nKbdInteractiveAuthentication yes\nAuthenticationMethods publickey,keyboard-interactive\n' >"$SSHD_DROPIN"
  printf '@include common-auth\naccount required pam_nologin.so\n@include common-account\n@include common-session\n' >"$PAM_SSHD"
  printf 'auth [success=1 default=ignore] pam_unix.so nullok\nauth requisite pam_deny.so\nauth required pam_permit.so\n' >"$PAM_COMMON_AUTH"
  access_set_user fixtureuser || fail 'fixture user'
  : >"$ACCESS_KEY_FILE"
  python3 - "$ACCESS_GA_FILE" <<'PY' || fail 'fixture TOTP creation'
import base64, pathlib, secrets, sys
pathlib.Path(sys.argv[1]).write_text(base64.b32encode(secrets.token_bytes(20)).decode() + '\n" TOTP_AUTH\n', encoding='ascii')
PY
  chmod 600 "$ACCESS_GA_FILE"
  fake_methods=publickey,keyboard-interactive:pam fake_password=no fake_pubkey=yes fake_kbd=yes fake_usepam=yes fake_root=yes
  fake_context_fail=0
}

sshd_eff_for() {
  printf '%s\n' "$1" >>"$work/contexts"
  ((fake_context_fail == 0)) || return 1
  printf 'port 2222\nusepam %s\npasswordauthentication %s\npubkeyauthentication %s\nkbdinteractiveauthentication %s\n' \
    "$fake_usepam" "$fake_password" "$fake_pubkey" "$fake_kbd"
  printf 'authenticationmethods %s\npermitrootlogin %s\nauthorizedkeysfile %s\npermitemptypasswords no\n' \
    "$fake_methods" "$fake_root" "$ACCESS_KEY_FILE"
}

sshd_eff() { : >"$work/global-fallback"; return 1; }
sshd_test() { return 0; }
ssh_reload() { return 0; }
systemctl() { return 1; }

fixture baseline
access_ssh_preflight fixtureuser >"$work/output" 2>&1 || { cat "$work/output"; fail 'standard SSH/PAM preflight'; }
cp "$PAM_SSHD" "$work/original-pam"
access_ssh_apply fixtureuser >"$work/output" 2>&1 || { cat "$work/output"; fail 'SSH access apply'; }
PAM_SELECTED=$(access_profile_pam fixtureuser)
grep -Fxq 'Subsystem sftp internal-sftp' "$SSHD_CONFIG" || fail 'global SSH configuration changed'
grep -Eq '^Match[[:space:]]+User[[:space:]]+fixtureuser[[:space:]]*$' "$SSHD_CONFIG" || fail 'missing per-user SSH match'
[[ $(grep -n '^Match ' "$SSHD_CONFIG" | head -n1 | cut -d: -f1) -gt $(grep -n '^Subsystem ' "$SSHD_CONFIG" | cut -d: -f1) ]] || fail 'Match precedes global-only directives'
grep -Fq 'publickey,keyboard-interactive:pam' "$SSHD_CONFIG" || fail 'missing mandatory SSH key plus PAM sequence'
grep -Eq '^[[:space:]]*AuthenticationMethods[[:space:]]+publickey,keyboard-interactive:pam[[:space:]]*$' "$SSHD_CONFIG" || fail 'SSH authentication alternatives allowed'
grep -Fq "$ACCESS_KEY_FILE" "$SSHD_CONFIG" || fail 'authorized key file does not belong to the selected user'
grep -Fxq 'account required pam_nologin.so' "$PAM_SSHD" || fail 'PAM account rule removed'
grep -Fxq 'session include common-session' "$PAM_SSHD" || fail 'PAM session rules removed or not scoped'
grep -Fxq 'account include common-account' "$PAM_SSHD" || fail 'PAM account rules removed or not scoped'
grep -Eq '^auth[[:space:]]+substack[[:space:]]+common-auth' "$PAM_SELECTED" || fail 'selected user does not require account authentication'
grep -Eq '^auth[[:space:]]+required[[:space:]]+pam_google_authenticator\.so' "$PAM_SELECTED" || fail 'selected user does not require TOTP'
grep -Fq "secret=$ACCESS_GA_FILE" "$PAM_SELECTED" || fail 'TOTP does not use selected user secret path'
grep -Eq '(^|[[:space:]])user=root([[:space:]]|$)' "$PAM_SELECTED" || fail 'central TOTP file lacks root reader'
grep -Eq '(^|[[:space:]])nullok([[:space:]]|$)' "$PAM_SELECTED" && fail 'unbound user could skip TOTP'
python3 - "$PAM_SSHD" "$PAM_SELECTED" "$PAM_ACCESS_LEGACY" <<'PY' || fail 'PAM selected/legacy routing'
import pathlib, re, sys
main, access, legacy = map(pathlib.Path, sys.argv[1:])
auth = []
for line in main.read_text().splitlines():
    text = line.strip()
    if re.match(r'auth\s', text):
        match = re.fullmatch(r'auth\s+(\[[^]]+\]|\S+)\s+(\S+)(?:\s+(.*))?', text)
        if not match:
            raise SystemExit('unrecognized PAM auth entry')
        auth.append(match.groups())
def selected_stacks(user):
    visited, position = [], 0
    while position < len(auth):
        control, module, arguments = auth[position]
        if module == 'pam_succeed_if.so':
            condition = re.search(r'\buser\s+(!=|=)\s+(\S+)', arguments or '')
            if condition is None:
                raise SystemExit('unsupported PAM branch')
            success = (user == condition[2]) == (condition[1] == '=')
            actions = dict(re.findall(r'(\w+)=(\w+)', control))
            result = actions.get('success' if success else 'auth_err', actions.get('default', 'bad'))
            if result.isdigit():
                position += int(result)
            elif result not in ('ignore', 'ok'):
                raise SystemExit('PAM branch fails unexpectedly')
        elif module in ('pam_deny.so', 'pam_permit.so'):
            raise SystemExit('normal authentication reached the uncached setcred gate')
        elif control in ('substack', 'include'):
            visited.append(pathlib.Path(module).name)
        else:
            raise SystemExit('unexpected top-level PAM auth rule')
        position += 1
    return visited
assert selected_stacks('fixtureuser') == [access.name], selected_stacks('fixtureuser')
assert selected_stacks('otheruser') == [legacy.name], selected_stacks('otheruser')
assert 'common-auth' in legacy.read_text()
PY
access_ssh_expect fixtureuser >"$work/output" 2>&1 || { cat "$work/output"; fail 'correct per-user SSH authentication rejected'; }
grep -Fxq fixtureuser "$work/contexts" || fail 'effective SSH values not checked for selected user'
for fake_methods in 'any' 'publickey' 'publickey keyboard-interactive:pam' 'publickey,keyboard-interactive:pam publickey'; do
  access_ssh_expect fixtureuser >"$work/output" 2>&1 && fail "accepted authentication alternative: $fake_methods"
done
fake_methods=publickey,keyboard-interactive:pam
fake_kbd=no
access_ssh_expect fixtureuser >"$work/output" 2>&1 && fail 'accepted disabled keyboard-interactive authentication'
fake_kbd=yes fake_pubkey=no
access_ssh_expect fixtureuser >"$work/output" 2>&1 && fail 'accepted disabled public-key authentication'
fake_pubkey=yes fake_usepam=no
access_ssh_expect fixtureuser >"$work/output" 2>&1 && fail 'accepted disabled PAM'
fake_usepam=yes
fake_context_fail=1
access_ssh_expect fixtureuser >"$work/output" 2>&1 && fail 'accepted failed per-user SSH evaluation'
[[ ! -e $work/global-fallback ]] || fail 'per-user validation fell back to global configuration'

fixture vhm-pam
printf 'session required pam_env.so\n#vhm# @include common-auth\nauth required pam_google_authenticator.so\n@include common-account\n@include common-session\n' >"$PAM_SSHD"
access_ssh_preflight fixtureuser >"$work/output" 2>&1 || { cat "$work/output"; fail 'existing vhm PAM preflight'; }
access_ssh_apply fixtureuser >"$work/output" 2>&1 || { cat "$work/output"; fail 'existing vhm PAM migration'; }
grep -Eq '^(@include[[:space:]]+common-auth|auth[[:space:]]+(substack|include)[[:space:]]+common-auth)' "$PAM_ACCESS_LEGACY" && fail 'old key plus TOTP path now requires an account password'
grep -Fxq 'auth required pam_google_authenticator.so' "$PAM_ACCESS_LEGACY" || fail 'legacy TOTP path was removed during migration'

fixture nested-match
printf 'Include %s/nested.conf\n' "$work" >"$work/sshd_config.d/20-local.conf"
printf 'Match User otheruser\n  PasswordAuthentication yes\n' >"$work/nested.conf"
access_ssh_preflight fixtureuser >"$work/output" 2>&1 && fail 'accepted unmanaged Match inside a recursive include'

fixture custom-pam
printf 'auth sufficient pam_permit.so\n' >>"$PAM_SSHD"
access_ssh_preflight fixtureuser >"$work/output" 2>&1 && fail 'accepted custom sufficient PAM authentication'

fixture root-disable-failure
change_begin 'access migration test' sshd
access_profile_track fixtureuser || fail 'rollback snapshots'
cp "$SSHD_CONFIG" "$work/original-sshd"
cp "$PAM_SSHD" "$work/original-pam"
access_ssh_apply fixtureuser || fail 'prepare strong administrator for rollback'
access_disable_root fixtureuser >"$work/output" 2>&1 && fail 'accepted root SSH still enabled after disable'
guard_abort >"$work/rollback" 2>&1 || { cat "$work/rollback"; fail 'root-disable failure rollback'; }
cmp -s "$SSHD_CONFIG" "$work/original-sshd" || fail 'root-disable rollback did not restore original SSH configuration'
cmp -s "$PAM_SSHD" "$work/original-pam" || fail 'root-disable rollback did not restore original PAM configuration'
[[ ! -e $ACCESS_PROFILES_STATE && ! -e $(access_profile_pam fixtureuser) ]] || fail 'root-disable rollback left profile metadata or PAM helper'
[[ $(<"$CHG_DIR/status") == rolled_back ]] || fail 'root-disable rollback state'

fixture root-disable-success
printf 'UsePAM yes\nPermitRootLogin yes\nPort 2222\nSubsystem sftp internal-sftp\n' >"$SSHD_CONFIG"
printf 'AllowUsers fixtureuser\nPort 4321\n' >"$SSHD_DROPIN"
cp "$SSHD_DROPIN" "$work/inactive-dropin"
access_disable_root fixtureuser >"$work/output" 2>&1 && fail 'disabled root before strong administrator profile was configured'
access_ssh_apply fixtureuser || fail 'prepare strong administrator for root disable'
cp "$PAM_SSHD" "$work/stage-one-pam"
fake_root=no
access_disable_root fixtureuser >"$work/output" 2>&1 || { cat "$work/output"; fail 'root SSH disable'; }
grep -Fxq 'PermitRootLogin yes' "$SSHD_CONFIG" || fail 'root disable changed legacy global settings'
awk '$1 == "Match" { user = $3 } $1 == "PermitRootLogin" && user == "root" && $2 == "no" { found = 1 } END { exit !found }' "$SSHD_CONFIG" || fail 'root SSH prohibition missing from root Match'
grep -Eiq '^[[:space:]]*Include' "$SSHD_CONFIG" && fail 'root disable activated an inactive drop-in'
cmp -s "$SSHD_DROPIN" "$work/inactive-dropin" || fail 'root disable changed an inactive drop-in'
cmp -s "$PAM_SSHD" "$work/stage-one-pam" || fail 'root disable rewrote the authentication stack'
grep -Fxq root "$work/contexts" || fail 'effective root SSH policy not verified'
grep -Fxq fixtureuser "$work/contexts" || fail 'target user not rechecked after closing root SSH'

echo 'PASS access-ssh'
