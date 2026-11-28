#!/usr/bin/env bash
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
test_dir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$test_dir"' EXIT
chmod 755 "$test_dir"
export VH_LOG=/dev/null VH_STATE="$test_dir/state" VH_CONF="$test_dir/config" VH_LOCK="$test_dir/lock"
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
# shellcheck source=scripts/lib/access-profiles.sh
source scripts/lib/access-profiles.sh

fail() { echo "FAIL $*" >&2; exit 1; }
_access_profile_owner_uid() { id -u; }
_access_profile_modules() { return 0; }
sshd_test() { return 0; }
sshd_eff() { : >"$work/global-fallback"; return 1; }

fixture() {
  work="$test_dir/$1"
  mkdir -p "$work/pam" "$work/sshd_config.d" "$work/keys" "$work/secrets" "$work/state" || fail 'fixture directories'
  chmod 755 "$work" "$work/pam" "$work/sshd_config.d" "$work/keys"
  chmod 700 "$work/state" "$work/secrets"
  SSHD_CONFIG="$work/sshd_config" PAM_SSHD="$work/pam/sshd"
  PAM_ACCESS_SSH="$work/pam/vhm-access-ssh" PAM_ACCESS_LEGACY="$work/pam/vhm-access-ssh-legacy"
  PAM_COMMON_AUTH="$work/pam/common-auth" PAM_PROFILE_PREFIX="$work/pam/vhm-ssh-user-"
  ACCESS_PROFILES_STATE="$work/state/profiles.json" VH_STATE="$work/state"
  printf 'Include %s/*.conf\nUsePAM yes\nPermitRootLogin no\nSubsystem sftp internal-sftp\n' "$work/sshd_config.d" >"$SSHD_CONFIG"
  printf '@include common-auth\naccount required pam_nologin.so\n@include common-account\n@include common-session\n' >"$PAM_SSHD"
  printf 'auth [success=1 default=ignore] pam_unix.so nullok\nauth requisite pam_deny.so\nauth required pam_permit.so\nauth optional pam_cap.so\n' >"$PAM_COMMON_AUTH"
  local user
  for user in root alice bob carol dave; do
    mkdir -p "$work/secrets/$user"
    chmod 700 "$work/secrets/$user"
    python3 - "$work/secrets/$user/totp" <<'PY' || fail 'fixture TOTP creation'
import base64, pathlib, secrets, sys
pathlib.Path(sys.argv[1]).write_text(base64.b32encode(secrets.token_bytes(20)).decode() + '\n" TOTP_AUTH\n', encoding='ascii')
PY
    chmod 600 "$work/secrets/$user/totp"
    printf 'fixture-public-key\n' >"$work/keys/$user"
    chmod 644 "$work/keys/$user"
  done
  fake_methods=publickey,keyboard-interactive:pam fake_password=no fake_pubkey=yes fake_kbd=yes fake_usepam=yes fake_context_fail=0
  fake_key="$work/keys/alice"
}

apply() {
  local user=$1 mode=$2
  access_profile_preflight "$user" "$mode" >"$work/output" 2>&1 &&
    access_profile_apply "$user" "$mode" "$work/keys/$user" "$work/secrets/$user/totp" >>"$work/output" 2>&1 || {
    cat "$work/output"; fail "apply $user $mode";
  }
}

fixture modes
# 同一项目可分别更新 root 和普通用户，每种更新都不得开放 root SSH。
for mode in password key password_totp key_totp; do
  apply root "$mode"
  apply alice "$mode"
  [[ $(access_profile_get root) == "$mode" && $(access_profile_get alice) == "$mode" ]] || fail 'independent profile metadata'
  grep -Fxq 'PermitRootLogin no' "$SSHD_CONFIG" || fail 'root SSH prohibition changed'
  [[ $(grep -ci 'permitrootlogin' "$SSHD_CONFIG") == 1 ]] || fail 'a Match block reopened root SSH'
done
[[ $(grep -c '^Match User root$' "$SSHD_CONFIG") == 1 ]] || fail 'root Match duplicated on update'
[[ $(grep -c '^Match User alice$' "$SSHD_CONFIG") == 1 ]] || fail 'ordinary-user Match duplicated on update'
grep -Fxq 'Subsystem sftp internal-sftp' "$SSHD_CONFIG" || fail 'global-only directive changed'
[[ $(grep -n '^Match ' "$SSHD_CONFIG" | head -n1 | cut -d: -f1) -gt $(grep -n '^Subsystem ' "$SSHD_CONFIG" | cut -d: -f1) ]] || fail 'Match precedes global configuration'
grep -Fxq '@include common-session' "$PAM_SSHD" || fail 'PAM session removed'
[[ $(stat -c %a "$ACCESS_PROFILES_STATE") == 600 ]] || fail 'metadata is not private'

fixture coexist
apply root key_totp
apply alice password_totp
apply bob key
apply carol key_password_totp
[[ $(access_profile_list | wc -l) == 4 ]] || fail 'multi-user metadata lost entries'
cp "$(access_profile_pam root)" "$work/root-helper-before"
cp "$(access_profile_pam carol)" "$work/carol-helper-before"
apply alice password
cmp -s "$(access_profile_pam root)" "$work/root-helper-before" || fail 'ordinary-user update changed root authentication'
cmp -s "$(access_profile_pam carol)" "$work/carol-helper-before" || fail 'ordinary-user update weakened strong administrator'
python3 - "$PAM_SSHD" "$PAM_ACCESS_LEGACY" "$work/pam" "$ACCESS_PROFILES_STATE" <<'PY' || fail 'multi-user PAM authentication routing'
import json, pathlib, re, sys
service, legacy, directory, metadata = map(pathlib.Path, sys.argv[1:])
auth = []
for raw in service.read_text().splitlines():
    line = raw.strip()
    if line.startswith('auth '):
        parsed = re.fullmatch(r'auth\s+(\[[^]]+\]|\S+)\s+(\S+)(?:\s+(.*))?', line)
        assert parsed, line
        auth.append(parsed.groups())
def authenticate(user, password=True, totp=True, condition_error=False):
    position, required_ok, visited = 0, True, []
    while position < len(auth):
        control, module, args = auth[position]
        if module == 'pam_succeed_if.so':
            name = re.search(r'\buser = (\S+)', args)[1]
            action = 'service_err' if condition_error else ('success' if user == name else 'auth_err')
            actions = dict(re.findall(r'(\w+)=(\w+)', control))
            result = actions.get(action, actions.get('default', 'bad'))
            if result.isdigit():
                position += int(result)
            elif result not in ('ignore', 'ok'):
                return False, visited
        else:
            assert control == 'substack', (control, module)
            visited.append(module)
            content = (directory / module).read_text()
            if re.search(r'^(?:@include common-auth|auth substack common-auth)$', content, re.M):
                required_ok &= password
            if re.search(r'^auth required pam_google_authenticator\.so\b', content, re.M):
                required_ok &= totp
        position += 1
    return required_ok, visited
profiles = json.loads(metadata.read_text())['profiles']
for user, profile in profiles.items():
    expected = 'vhm-ssh-user-' + user
    assert authenticate(user) == (True, [expected]), (user, authenticate(user))
    needs_password = profile['mode'] in ('password', 'password_totp', 'key_password_totp') or profile['mode'] == 'key'
    needs_totp = profile['mode'].endswith('_totp')
    assert authenticate(user, password=False)[0] == (not needs_password), user
    assert authenticate(user, totp=False)[0] == (not needs_totp), user
    assert not authenticate(user, condition_error=True)[0], user
assert authenticate('unmanaged') == (True, [legacy.name])
assert not authenticate('unmanaged', password=False)[0]
assert profiles['carol']['mode'] == 'key_password_totp'
assert 'auth substack common-auth' in (directory / 'vhm-ssh-user-carol').read_text()
assert 'nullok' not in (directory / 'vhm-ssh-user-carol').read_text()
PY

# 精确检查指定用户真实上下文；认证方法空格替代是 OR，必须拒绝。
sshd_eff_for() {
  printf '%s\n' "$1" >>"$work/contexts"
  ((fake_context_fail == 0)) || return 1
  printf 'authenticationmethods %s\npasswordauthentication %s\npubkeyauthentication %s\nkbdinteractiveauthentication %s\nusepam %s\npermitemptypasswords no\nauthorizedkeysfile %s\n' \
    "$fake_methods" "$fake_password" "$fake_pubkey" "$fake_kbd" "$fake_usepam" "$fake_key"
}
access_profile_expect alice key_totp "$fake_key" || fail 'valid exact authentication sequence'
for fake_methods in any publickey 'publickey keyboard-interactive:pam' 'publickey,keyboard-interactive:pam publickey'; do
  access_profile_expect alice key_totp "$fake_key" >"$work/output" 2>&1 && fail "accepted alternative: $fake_methods"
done
fake_methods=publickey,keyboard-interactive:pam fake_context_fail=1
access_profile_expect alice key_totp "$fake_key" >"$work/output" 2>&1 && fail 'failed user context accepted'
[[ ! -e $work/global-fallback ]] || fail 'context verification fell back to global display'

fixture snapshot
apply root key_totp
tracked="$work/tracked"
change_track() { printf '%s\n' "$1" >>"$tracked"; }
access_profile_track alice || fail 'profile snapshot enumeration'
for path in "$SSHD_CONFIG" "$PAM_SSHD" "$PAM_ACCESS_LEGACY" "$ACCESS_PROFILES_STATE" "$(access_profile_pam root)" "$(access_profile_pam alice)"; do
  grep -Fxq "$path" "$tracked" || fail "snapshot missing $path"
done

fixture legacy-totp
printf '#vhm# @include common-auth\nauth required pam_google_authenticator.so\n@include common-account\n@include common-session\n' >"$PAM_SSHD"
apply alice password_totp
grep -Fxq '#vhm# @include common-auth' "$PAM_ACCESS_LEGACY" || fail 'legacy commented password restored unexpectedly'
grep -Fxq 'auth required pam_google_authenticator.so' "$PAM_ACCESS_LEGACY" || fail 'legacy TOTP was removed'

fixture unmanaged-match
printf 'Include %s/nested.conf\n' "$work" >"$work/sshd_config.d/local.conf"
printf 'Match User bob\n  PasswordAuthentication yes\n' >"$work/nested.conf"
access_profile_preflight alice key >"$work/output" 2>&1 && fail 'unmanaged recursive Match accepted'

fixture unsafe-pam
printf 'auth sufficient pam_permit.so\n' >>"$PAM_SSHD"
access_profile_preflight alice key >"$work/output" 2>&1 && fail 'custom PAM bypass accepted'

fixture custom-password
printf 'auth sufficient pam_permit.so\n' >>"$PAM_COMMON_AUTH"
access_profile_preflight alice password_totp >"$work/output" 2>&1 && fail 'custom common-auth bypass accepted'

fixture drift
apply alice password_totp
printf 'auth sufficient pam_permit.so\n' >>"$(access_profile_pam alice)"
access_profile_preflight root key >"$work/output" 2>&1 && fail 'modified managed PAM helper accepted'

fixture unsafe-secret
chmod 644 "$work/secrets/alice/totp"
access_profile_apply alice key_totp "$work/keys/alice" "$work/secrets/alice/totp" >"$work/output" 2>&1 && fail 'public TOTP secret accepted'
[[ ! -e $ACCESS_PROFILES_STATE && ! -e $PAM_ACCESS_LEGACY ]] || fail 'secret rejection mutated authentication'

echo 'PASS access-profiles'
