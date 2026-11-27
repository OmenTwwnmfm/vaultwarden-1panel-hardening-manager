#!/usr/bin/env bash
# 断言 vhm 的 systemd 单元：内容相同不重写；项目目录变化或升级后自动改写已安装的单元；未安装的不创建
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/units"
printf '#!/usr/bin/env bash\necho "$*" >>"%s/systemctl.log"\nexit 0\n' "$T" >"$T/bin/systemctl"
chmod +x "$T/bin/systemctl"
export PATH="$T/bin:$PATH" VH_STATE="$T/state" VH_LOG=/dev/null
export F2B_SYNC_SERVICE="$T/units/vhm-ssh-port-sync.service" F2B_SYNC_PATH="$T/units/vhm-ssh-port-sync.path"
export F2B_SYNC_TIMER="$T/units/vhm-ssh-port-sync.timer" GUARD_BOOT_UNIT="$T/units/vhm-guard-boot.service"
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
fail=0

unit_write "$T/u" "x"
rc=0; unit_write "$T/u" "x" || rc=$?
[[ $rc == 1 ]] || { echo "FAIL 内容相同仍被重写（rc=$rc）"; fail=1; }

# 未安装任何单元：不创建
vh_units_refresh >/dev/null 2>&1
[[ ! -e $F2B_SYNC_SERVICE && ! -e $GUARD_BOOT_UNIT ]] || { echo "FAIL 未安装的单元被创建"; fail=1; }

# 旧版本（旧路径、15 秒定时器）安装的单元
printf '[Service]\nExecStart=/bin/bash /old/place/scripts/vh-fail2ban.sh sync-port\n' >"$F2B_SYNC_SERVICE"
printf '[Timer]\nOnUnitActiveSec=15s\n' >"$F2B_SYNC_TIMER"
printf '[Service]\nExecStart=/bin/bash /old/place/scripts/vh-changes.sh boot-rollback\n' >"$GUARD_BOOT_UNIT"
: >"$T/systemctl.log"
vh_units_refresh >/dev/null 2>&1
grep -Fq "ExecStart=/bin/bash $VH_DIR/vh-fail2ban.sh sync-port" "$F2B_SYNC_SERVICE" || { echo "FAIL Fail2Ban 同步服务路径未更新"; fail=1; }
grep -Fq "ExecStart=/bin/bash $VH_DIR/vh-changes.sh boot-rollback" "$GUARD_BOOT_UNIT" || { echo "FAIL 开机回滚服务路径未更新"; fail=1; }
grep -Fxq 'OnUnitActiveSec=5min' "$F2B_SYNC_TIMER" || { echo "FAIL 同步定时器间隔未更新"; fail=1; }
grep -Fxq 'PathModified=/etc/ssh/sshd_config.d' "$F2B_SYNC_PATH" || { echo "FAIL .path 未监视整个 drop-in 目录"; fail=1; }
grep -q daemon-reload "$T/systemctl.log" || { echo "FAIL 改写后未 daemon-reload"; fail=1; }

# 再次运行：无需改写，不 reload
: >"$T/systemctl.log"
vh_units_refresh >/dev/null 2>&1
[[ ! -s $T/systemctl.log ]] || { echo "FAIL 内容未变化仍调用了 systemctl"; fail=1; }

# 启动器开启了 set -e：无需改写时也不能中断
bash -ec 'source scripts/vh-common.sh; vh_units_refresh; echo survived' 2>/dev/null | grep -qx survived ||
  { echo "FAIL set -e 下 vh_units_refresh 中断了启动器"; fail=1; }
rm -f "$F2B_SYNC_SERVICE" "$GUARD_BOOT_UNIT"
bash -ec 'source scripts/vh-common.sh; vh_units_refresh; echo survived' 2>/dev/null | grep -qx survived ||
  { echo "FAIL set -e 下未安装单元时中断了启动器"; fail=1; }

((fail == 0)) && echo "PASS units-refresh"
exit $fail
