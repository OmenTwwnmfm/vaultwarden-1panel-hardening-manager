#!/usr/bin/env bash
# 公共入口：路径与颜色等全局变量，然后按主题加载 lib/ 中的函数库
# shellcheck disable=SC2034
F2B_SYNC_PATH=${F2B_SYNC_PATH:-/etc/systemd/system/vhm-ssh-port-sync.path}
F2B_SYNC_SERVICE=${F2B_SYNC_SERVICE:-/etc/systemd/system/vhm-ssh-port-sync.service}
F2B_SYNC_TIMER=${F2B_SYNC_TIMER:-/etc/systemd/system/vhm-ssh-port-sync.timer}

VH_DIR=${VH_DIR:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"}
VH_VERSION="$(cat "$VH_DIR/../VERSION" 2>/dev/null || echo unknown)"
VH_CONF=${VH_CONF:-/etc/vaultwarden-hardening.conf}
VH_STATE=${VH_STATE:-/var/lib/vaultwarden-hardening}
VH_LOG=${VH_LOG:-/var/log/vaultwarden-hardening.log}
VH_LOCK=${VH_LOCK:-/run/lock/vaultwarden-hardening.lock}
VH_CHANGES=${VH_CHANGES:-$VH_STATE/changes}
VH_EXIT_LOCKED=75
GUARD_SECONDS=${GUARD_SECONDS:-300}

SSHD_CONFIG=${SSHD_CONFIG:-/etc/ssh/sshd_config}
SSHD_DROPIN=${SSHD_DROPIN:-/etc/ssh/sshd_config.d/00-vhm.conf}
SSH_SOCKET_DROPIN=${SSH_SOCKET_DROPIN:-/etc/systemd/system/ssh.socket.d/00-vhm.conf}
PAM_SSHD=${PAM_SSHD:-/etc/pam.d/sshd}
GA_FILE=${GA_FILE:-/root/.google_authenticator}
ROOT_KEYS=${ROOT_KEYS:-/root/.ssh/authorized_keys}
ACCESS_STATE=${ACCESS_STATE:-$VH_STATE/access.conf}
ACCESS_KEYS_DIR=${ACCESS_KEYS_DIR:-/etc/ssh/vhm-authorized-keys}
ACCESS_SECRETS_DIR=${ACCESS_SECRETS_DIR:-/etc/security/vhm-access}
PAM_ACCESS_SSH=${PAM_ACCESS_SSH:-/etc/pam.d/vhm-access-ssh}
PAM_ACCESS_LEGACY=${PAM_ACCESS_LEGACY:-/etc/pam.d/vhm-access-ssh-legacy}
F2B_JAIL=${F2B_JAIL:-/etc/fail2ban/jail.d/vhm-sshd.local}
SYSCTL_FILE=${SYSCTL_FILE:-/etc/sysctl.d/90-vhm-hardening.conf}
AUTO_UPGRADES=${AUTO_UPGRADES:-/etc/apt/apt.conf.d/20auto-upgrades}

VBM_CONF=${VBM_CONF:-/etc/vaultwarden-backup.conf}
VBM_LOCK=${VBM_LOCK:-/run/lock/vaultwarden-backup.lock}
VBM_WORKER=${VBM_WORKER:-/usr/local/sbin/vw-backup.sh}
VBM_RUNS=${VBM_RUNS:-/var/lib/vaultwarden-backup/runs}

if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[36m' C_D=$'\e[2m' C_0=$'\e[0m'
else
  C_R='' C_G='' C_Y='' C_B='' C_D='' C_0=''
fi

# ---------- 函数库 ----------
# 按主题拆分在 lib/ 中；加载顺序与拆分前的定义顺序一致
# shellcheck source=scripts/lib/base.sh
source "$VH_DIR/lib/base.sh"
# shellcheck source=scripts/lib/vaultwarden.sh
source "$VH_DIR/lib/vaultwarden.sh"
# shellcheck source=scripts/lib/changes.sh
source "$VH_DIR/lib/changes.sh"
# shellcheck source=scripts/lib/ssh.sh
source "$VH_DIR/lib/ssh.sh"
# shellcheck source=scripts/lib/access-sudo.sh
source "$VH_DIR/lib/access-sudo.sh"
# shellcheck source=scripts/lib/access-profiles.sh
source "$VH_DIR/lib/access-profiles.sh"
# shellcheck source=scripts/lib/firewall.sh
source "$VH_DIR/lib/firewall.sh"
# shellcheck source=scripts/lib/panel.sh
source "$VH_DIR/lib/panel.sh"
# shellcheck source=scripts/lib/fail2ban.sh
source "$VH_DIR/lib/fail2ban.sh"
# shellcheck source=scripts/lib/legacy.sh
source "$VH_DIR/lib/legacy.sh"
# shellcheck source=scripts/lib/update.sh
source "$VH_DIR/lib/update.sh"
