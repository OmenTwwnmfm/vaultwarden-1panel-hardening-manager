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
cleanup() {
  if [[ -n $sshd_pid ]]; then kill "$sshd_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT
export VH_STATE="$work/state" VH_CHANGES="$work/state/changes" VH_LOG=/dev/null
export VH_LOCK="$work/lock" VH_CONF="$work/hardening.conf"
export SSHD_CONFIG=/etc/ssh/sshd_config PAM_SSHD=/etc/pam.d/sshd
unset SSH_CONNECTION SSH_CLIENT

useradd --create-home --shell /bin/bash --groups sudo vhmaccess
useradd --create-home --shell /bin/bash --groups sudo vhmlegacy
useradd --create-home --shell /bin/bash vhmkey
install -d -m 755 /run/sshd
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
LogLevel ERROR
EOF

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
for attempt in range(100):
    try:
        with socket.create_connection(("127.0.0.1", 2222), timeout=0.2):
            break
    except OSError:
        time.sleep(0.1)
else:
    raise SystemExit("FAIL access-auth: SSH server did not start")
PY
}

restart_sshd() {
  kill "$sshd_pid"
  wait "$sshd_pid" || true
  sshd_pid=''
  start_sshd
}

start_sshd
python3 tests/integration/access-auth.py baseline "$work"
change_begin 'Integration access configuration'
record=$CHG_DIR
change_track "$SSHD_DROPIN"
access_profile_track vhmaccess
access_sudo_track

access_ssh_preflight vhmaccess
access_sudo_preflight vhmaccess
access_ssh_apply vhmaccess
access_ssh_expect vhmaccess
restart_sshd
python3 tests/integration/access-auth.py stage-one "$work"

access_sudo_apply vhmaccess "$ACCESS_GA_FILE"
access_sudo_verify vhmaccess "$ACCESS_GA_FILE"
visudo --check >/dev/null 2>&1
access_disable_root vhmaccess
access_ssh_expect vhmaccess
restart_sshd
python3 tests/integration/access-auth.py stage-two "$work"

change_restore_files "$record"
visudo --check >/dev/null 2>&1
restart_sshd
python3 tests/integration/access-auth.py rollback "$work"

# Verify independent root/user PAM routes and multiple trailing Match blocks.
# This is a separate change after a complete rollback of the strong-admin mode.
change_begin 'Integration independent user profiles'
profile_record=$CHG_DIR
for user in root vhmaccess vhmkey; do access_profile_track "$user"; done
access_profile_preflight root key_totp
access_profile_apply root key_totp "$ACCESS_KEYS_DIR/root" "$ACCESS_SECRETS_DIR/root/totp"
access_profile_preflight vhmaccess password_totp
access_profile_apply vhmaccess password_totp '' "$ACCESS_SECRETS_DIR/vhmaccess/totp"
access_profile_preflight vhmkey key
access_profile_apply vhmkey key "$ACCESS_KEYS_DIR/vhmkey" ''
access_profile_expect root key_totp "$ACCESS_KEYS_DIR/root"
access_profile_expect vhmaccess password_totp
access_profile_expect vhmkey key "$ACCESS_KEYS_DIR/vhmkey"
restart_sshd
python3 tests/integration/access-auth.py profiles "$work"

# Updating one user must preserve root key+TOTP and the other user's key login.
access_profile_preflight vhmaccess password
access_profile_apply vhmaccess password '' ''
access_profile_expect root key_totp "$ACCESS_KEYS_DIR/root"
access_profile_expect vhmaccess password
access_profile_expect vhmkey key "$ACCESS_KEYS_DIR/vhmkey"
restart_sshd
python3 tests/integration/access-auth.py profiles-updated "$work"

change_restore_files "$profile_record"
restart_sshd
python3 tests/integration/access-auth.py rollback "$work"
echo 'PASS access-auth integration'
