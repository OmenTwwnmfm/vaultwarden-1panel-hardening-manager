#!/usr/bin/env bash
set +x
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if [[ ${VHM_ACCESS_INTEGRATION:-0} != 1 || ! -f /.dockerenv || $EUID != 0 ]]; then
  echo 'Run only inside a disposable Docker container with VHM_ACCESS_INTEGRATION=1' >&2
  exit 1
fi

for dependency in /usr/sbin/sshd useradd chpasswd ssh-keygen python3 visudo; do
  command -v "$dependency" >/dev/null || { echo 'Missing integration test dependency' >&2; exit 1; }
done

work=$(mktemp -d /run/vhm-access-test.XXXXXX)
sshd_pid=''
stage=fixture
cleanup() {
  local status=$1
  if [[ -n $sshd_pid ]]; then
    kill "$sshd_pid" 2>/dev/null || true
    wait "$sshd_pid" 2>/dev/null || true
  fi
  if ((status != 0)); then
    printf 'FAIL access-auth stage=%s status=%d\n' "$stage" "$status" >&2
    if [[ -s $work/sshd.log ]]; then
      # sshd uses VERBOSE, and all clients and accounts here belong to this fixture.
      # Only include server lifecycle, connection, and error lines in CI output.
      grep -Ei '^(sshd(-session|-auth)?: |fatal: |error: |Server listening |Connection |Accepted |Failed |Unable to negotiate |PAM: )' \
        "$work/sshd.log" | tail -n 30 >&2 || true
    fi
  fi
  rm -rf -- "$work"
}
trap 'cleanup "$?"' EXIT
export VH_STATE="$work/state" VH_CHANGES="$work/state/changes" VH_LOG=/dev/null
export VH_LOCK="$work/lock" VH_CONF="$work/hardening.conf"
export SSHD_CONFIG=/etc/ssh/sshd_config PAM_SSHD=/etc/pam.d/sshd
unset SSH_CONNECTION SSH_CLIENT

useradd --create-home --shell /bin/bash --groups sudo vhmaccess
useradd --create-home --shell /bin/bash --groups sudo vhmlegacy
useradd --create-home --shell /bin/bash vhmkey
install -d -m 755 /run/sshd
install -d -m 700 "$work/project/scripts/lib"
install -m 600 VERSION "$work/project/VERSION"
install -m 600 scripts/*.sh "$work/project/scripts/"
install -m 600 scripts/lib/*.sh "$work/project/scripts/lib/"
test ! -e /usr/local/bin/vhm
cat >/usr/local/bin/vhm <<EOF
#!/bin/bash
export VH_STATE='$VH_STATE' VH_CHANGES='$VH_CHANGES' VH_LOG=/dev/null
export VH_LOCK='$VH_LOCK' VH_CONF='$VH_CONF'
exec bash '$work/project/scripts/vh-launcher.sh' "\$@"
EOF
chmod 755 /usr/local/bin/vhm
ssh-keygen -q -t ed25519 -N '' -f "$work/hostkey"
cat >"$SSHD_CONFIG" <<EOF
Port 2222
ListenAddress 127.0.0.1
HostKey $work/hostkey
PidFile $work/sshd.pid
UsePAM yes
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
AuthenticationMethods any
AuthorizedKeysFile .ssh/authorized_keys
StrictModes yes
PermitEmptyPasswords no
UseDNS no
PrintMotd no
LogLevel VERBOSE
EOF

# This file is intentionally outside the main config's Includes.
inert_dropin=/etc/ssh/sshd_config.d/77-vhm-unreferenced.conf
install -d -m 755 "${inert_dropin%/*}"
printf 'Port 23222\nAllowUsers vhmkey\n' >"$work/inert-dropin.conf"
install -m 644 "$work/inert-dropin.conf" "$inert_dropin"

# shellcheck source=scripts/vh-access.sh
source scripts/vh-access.sh
access_set_user vhmaccess
install -d -m 755 "$(dirname "$ACCESS_KEY_FILE")"
install -d -m 700 "$(dirname "$ACCESS_GA_FILE")"
python3 tests/integration/access-auth.py fixture "$work" --key-file "$ACCESS_KEY_FILE" --seed-file "$ACCESS_GA_FILE"

start_sshd() {
  /usr/sbin/sshd -t -f "$SSHD_CONFIG"
  /usr/sbin/sshd -D -e -f "$SSHD_CONFIG" 2>"$work/sshd.log" &
  sshd_pid=$!
  python3 - <<'PY'
import socket
import time

deadline = time.monotonic() + 10
state = "no connection attempt"
while time.monotonic() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", 2222), timeout=1) as client:
            with client.makefile("rb") as reader:
                if reader.readline(256).startswith(b"SSH-2.0-"):
                    break
        state = "connection closed before the SSH banner"
    except OSError as error:
        state = type(error).__name__
    time.sleep(0.1)
else:
    raise SystemExit("FAIL access-auth: SSH server did not send a banner (" + state + ")")
PY
}

restart_sshd() {
  kill "$sshd_pid"
  wait "$sshd_pid" || true
  sshd_pid=''
  start_sshd
}

expect_inert_dropin() {
  if ! cmp -s "$work/inert-dropin.conf" "$inert_dropin"; then
    echo 'FAIL access-auth: unrelated SSH drop-in changed' >&2
    return 1
  fi
  access_expect_for vhmlegacy 127.0.0.1 port 2222 &&
    access_expect_for vhmlegacy 127.0.0.1 allowusers ''
}

stage=baseline
expect_inert_dropin
access_expect_for root 127.0.0.1 permitrootlogin yes
start_sshd
python3 tests/integration/access-auth.py baseline "$work"
stage='stage-one'
change_begin 'Integration access configuration'
record=$CHG_DIR
access_profile_track vhmaccess
access_sudo_track

access_ssh_preflight vhmaccess
access_sudo_preflight vhmaccess
access_ssh_apply vhmaccess
access_ssh_expect vhmaccess
access_sudo_apply vhmaccess "$ACCESS_GA_FILE"
access_sudo_verify vhmaccess "$ACCESS_GA_FILE"
restart_sshd
python3 tests/integration/access-auth.py "$stage" "$work"
stage='verify-login'
printf '%s\n' vhmaccess >"$record/access-user"
printf '%s\n' login >"$record/access-phase"
python3 tests/integration/access-auth.py "$stage" "$work" --change "$CHG_ID"

stage='stage-two'
visudo --check >/dev/null 2>&1
access_disable_root vhmaccess
access_ssh_expect vhmaccess
expect_inert_dropin
access_expect_for vhmlegacy 127.0.0.1 permitrootlogin yes
restart_sshd
python3 tests/integration/access-auth.py "$stage" "$work"
stage='verify-final'
printf '%s\n' final >"$record/access-phase"
python3 tests/integration/access-auth.py "$stage" "$work" --change "$CHG_ID"

stage='strong-admin-rollback'
change_restore_files "$record"
visudo --check >/dev/null 2>&1
restart_sshd
python3 tests/integration/access-auth.py rollback "$work"

# Verify independent root/user PAM routes and multiple trailing Match blocks.
# This is a separate change after a complete rollback of the strong-admin mode.
stage=profiles
change_begin 'Integration independent user profiles'
profile_record=$CHG_DIR
for user in root vhmaccess vhmkey; do access_profile_track "$user"; done
# Keep the global root setting closed and prove the explicit root profile is scoped.
sed -i 's/^PermitRootLogin yes$/PermitRootLogin no/' "$SSHD_CONFIG"
access_expect_for root 127.0.0.1 permitrootlogin no
access_profile_preflight root key_totp
access_profile_apply root key_totp "$ACCESS_KEYS_DIR/root" "$ACCESS_SECRETS_DIR/root/totp" yes
access_profile_preflight vhmaccess password_totp
access_profile_apply vhmaccess password_totp '' "$ACCESS_SECRETS_DIR/vhmaccess/totp"
access_profile_preflight vhmkey key
access_profile_apply vhmkey key "$ACCESS_KEYS_DIR/vhmkey" ''
access_profile_expect root key_totp "$ACCESS_KEYS_DIR/root"
access_profile_expect vhmaccess password_totp
access_profile_expect vhmkey key "$ACCESS_KEYS_DIR/vhmkey"
access_expect_for root 127.0.0.1 permitrootlogin yes
access_expect_for vhmlegacy 127.0.0.1 permitrootlogin no
expect_inert_dropin
restart_sshd
python3 tests/integration/access-auth.py "$stage" "$work"

# Updating one user must preserve root key+TOTP and the other user's key login.
stage='profiles-updated'
access_profile_preflight vhmaccess password
access_profile_apply vhmaccess password '' ''
access_profile_expect root key_totp "$ACCESS_KEYS_DIR/root"
access_profile_expect vhmaccess password
access_profile_expect vhmkey key "$ACCESS_KEYS_DIR/vhmkey"
access_expect_for root 127.0.0.1 permitrootlogin yes
expect_inert_dropin
restart_sshd
python3 tests/integration/access-auth.py "$stage" "$work"

stage='profile-rollback'
change_restore_files "$profile_record"
restart_sshd
python3 tests/integration/access-auth.py rollback "$work"
echo 'PASS access-auth integration'
