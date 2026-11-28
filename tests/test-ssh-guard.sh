#!/usr/bin/env bash
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
test_dir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$test_dir"' EXIT
export VH_LOG=/dev/null
# shellcheck source=scripts/vh-ssh.sh
source scripts/vh-ssh.sh

fail() { echo "FAIL $*" >&2; exit 1; }

fixture() {
  work="$test_dir/$1"
  mkdir -p "$work/sshd_config.d" || fail "test directory"
  VH_STATE="$work/state" VH_CHANGES="$work/state/changes"
  VH_CONF="$work/hardening.conf" VH_LOCK="$work/lock" GUARD_BOOT_UNIT="$work/vhm-guard-boot.service"
  SSHD_CONFIG="$work/sshd_config" SSHD_DROPIN="$work/sshd_config.d/00-vhm.conf" PAM_SSHD="$work/sshd.pam"
  SSH_SOCKET_DROPIN="$work/ssh.socket.conf" F2B_JAIL="$work/f2b.local"
  printf 'Port 22\n' >"$SSHD_CONFIG"
  printf '@include common-auth\n' >"$PAM_SSHD"
  boot_fail=0 timer_fail=0 external_port=0
}

systemctl() {
  case $1 in
    daemon-reload) return 0 ;;
    is-enabled | is-active) return 1 ;;
    enable) ((boot_fail == 0)) ;;
    stop) : >"$work/stopped" ;;
    *) return 1 ;;
  esac
}

systemd-run() {
  [[ -f $CHG_DIR/guard ]] || fail "missing boot rollback marker"
  grep -Fq -- "$SSHD_CONFIG" "$CHG_DIR/files.tsv" || fail "missing main SSH configuration snapshot"
  grep -Fq -- "$SSHD_DROPIN" "$CHG_DIR/files.tsv" || fail "missing SSH drop-in snapshot"
  [[ $(<"$SSHD_CONFIG") == 'Port 22' && ! -e $SSHD_DROPIN ]] || fail "SSH files changed before guard setup"
  : >"$work/timer-attempted"
  ((timer_fail == 0))
}

sshd_eff() {
  awk '{ print tolower($1), $2 }' "$SSHD_CONFIG"
  if [[ -f $SSHD_DROPIN ]]; then awk '{ print tolower($1), $2 }' "$SSHD_DROPIN"; fi
  if ((external_port)); then echo 'port 22'; fi
}

ssh_reload() {
  printf '%s %s\n' "$(<"$CHG_DIR/status")" "$(effective_ports | paste -sd, -)" >>"$work/reloads"
}

confirm_yes() { return 0; }
ss() { return 0; }
wait_port_allowed() { return 0; }
ssh_socket_used() { return 1; }
load_keys() { KEY_FP=(test-key); }
test_cmd() { echo '测试连接'; }

fixture boot-failure
boot_fail=1
configure_auth_mode key >"$work/output" 2>&1 && fail "authentication proceeded without boot protection"
[[ ! -e $work/timer-attempted && ! -e $work/reloads && ! -e $SSHD_DROPIN ]] || fail "activity after boot guard failure"
[[ $(<"$SSHD_CONFIG") == 'Port 22' && $(<"$PAM_SSHD") == '@include common-auth' ]] || fail "authentication files changed after boot guard failure"

fixture timer-failure
timer_fail=1
change_port <<<2202 >"$work/output" 2>&1 && fail "port change proceeded without timer"
[[ -e $work/timer-attempted && ! -e $work/reloads && ! -e $SSHD_DROPIN && $(<"$SSHD_CONFIG") == 'Port 22' ]] || fail "port changed after timer failure"

fixture port-success
change_port <<<$'2202\nyes' >"$work/output" 2>&1 || { cat "$work/output"; fail "confirmed port change"; }
[[ $(<"$work/reloads") == $'pending 22,2202\npending 2202' ]] || fail "guard did not stay pending through final reload"
[[ $(<"$CHG_DIR/status") == confirmed && -e $work/stopped ]] || fail "port change did not commit and disarm"

fixture extra-port
external_port=1
change_port <<<$'2202\nyes' >"$work/output" 2>&1 && fail "port change accepted an extra effective port"
[[ $(<"$work/reloads") == $'pending 22,2202\npending 22' ]] || fail "old configuration was not reloaded on validation failure"
[[ $(<"$CHG_DIR/status") == rolled_back && ! -e $SSHD_DROPIN && -e $work/stopped ]] || fail "extra port was not rolled back"

fixture confirmation-failure
change_begin 'test change'
change_write_status() { return 1; }
guard_confirm >"$work/output" 2>&1 && fail "failed status write was accepted"
[[ $(<"$CHG_DIR/status") == pending && ! -e $work/stopped ]] || fail "failed status write disarmed the guard"

echo 'PASS ssh-guard'
