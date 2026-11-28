#!/usr/bin/env bash
# 断言变更记录：修改前备份、回滚恢复内容与权限、新建文件回滚后删除、重复回滚无副作用
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VH_STATE="$T/state" VH_LOG=/dev/null VH_LOCK="$T/lock"
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
fail=0
printf 'old\n' >"$T/a.conf"
chmod 640 "$T/a.conf"
change_begin "测试变更" >/dev/null
change_track "$T/a.conf"
change_track "$T/a.conf" # 同一路径只记录一次
change_track "$T/new.conf"
printf 'new\n' >"$T/a.conf"
chmod 644 "$T/a.conf"
printf 'x\n' >"$T/new.conf"
change_status applied
[[ $(wc -l <"$CHG_DIR/files.tsv") -eq 2 ]] || { echo "FAIL 重复记录"; fail=1; }
change_rollback "$CHG_ID" >/dev/null 2>&1 || { echo "FAIL 回滚返回非 0"; fail=1; }
[[ $(cat "$T/a.conf") == old ]] || { echo "FAIL 内容未恢复"; fail=1; }
[[ $(stat -c %a "$T/a.conf") == 640 ]] || { echo "FAIL 权限未恢复"; fail=1; }
[[ ! -e $T/new.conf ]] || { echo "FAIL 新建文件未删除"; fail=1; }
[[ $(cat "$CHG_DIR/status") == rolled_back ]] || { echo "FAIL 状态未更新"; fail=1; }
printf 'later\n' >"$T/a.conf"
change_rollback "$CHG_ID" >/dev/null 2>&1
[[ $(cat "$T/a.conf") == later ]] || { echo "FAIL 重复回滚覆盖了后来的修改"; fail=1; }
change_rollback "bad/../id" >/dev/null 2>&1 && { echo "FAIL 接受了非法 ID"; fail=1; }
mkdir "$T/dir.conf"
change_begin "目录" >/dev/null
change_track "$T/dir.conf" 2>/dev/null && { echo "FAIL 接受了目录"; fail=1; }

# 回滚失败必须留下可重试的记录，不能标记成已回滚；非 root 才能用只读目录模拟失败
if ((EUID != 0)); then
  mkdir "$T/ro"
  printf 'keep\n' >"$T/ro/file.conf"
  change_begin "回滚失败" >/dev/null
  change_track "$T/ro/file.conf"
  change_track "$T/ro/new.conf"
  printf 'changed\n' >"$T/ro/file.conf"
  printf 'new\n' >"$T/ro/new.conf"
  change_status applied
  chmod 500 "$T/ro"
  change_rollback "$CHG_ID" >/dev/null 2>&1 && { echo "FAIL 回滚失败却返回 0"; fail=1; }
  [[ $(cat "$CHG_DIR/status") == rollback_failed ]] || { echo "FAIL 失败状态不是 rollback_failed"; fail=1; }
  chmod 700 "$T/ro"
  change_rollback "$CHG_ID" >/dev/null 2>&1 || { echo "FAIL 修复后重试回滚失败"; fail=1; }
  [[ $(cat "$T/ro/file.conf") == keep ]] || { echo "FAIL 重试后内容未恢复"; fail=1; }
  [[ ! -e $T/ro/new.conf ]] || { echo "FAIL 重试后新建文件未删除"; fail=1; }
  [[ $(cat "$CHG_DIR/status") == rolled_back ]] || { echo "FAIL 重试后状态不是 rolled_back"; fail=1; }
fi

# Earlier SSH rollback cannot overwrite a later profile; the newest record can be rolled back first.
SSHD_CONFIG="$T/sshd_config"
PAM_SSHD="$T/pam-sshd"
ACCESS_STATE="$T/access.conf"
ssh_reload() { printf 'reload\n' >>"$T/ssh-reloads"; }
printf 'original ssh\n' >"$SSHD_CONFIG"
printf 'original pam\n' >"$PAM_SSHD"
change_begin '旧 SSH 变更' sshd >/dev/null
old_ssh_id=$CHG_ID
change_track "$SSHD_CONFIG"
change_track "$PAM_SSHD"
printf 'older ssh\n' >"$SSHD_CONFIG"
printf 'older pam\n' >"$PAM_SSHD"
change_status confirmed
change_begin '新普通管理员迁移' sshd >/dev/null
new_ssh_id=$CHG_ID
change_track "$SSHD_CONFIG"
change_track "$PAM_SSHD"
change_track "$ACCESS_STATE"
printf 'newer ssh\n' >"$SSHD_CONFIG"
printf 'newer pam\n' >"$PAM_SSHD"
printf 'active\n' >"$ACCESS_STATE"
change_status confirmed
change_rollback "$old_ssh_id" >"$T/overlap-output" 2>&1 && { echo 'FAIL 旧 SSH 回滚覆盖较新认证配置'; fail=1; }
grep -Fq "$new_ssh_id" "$T/overlap-output" || { echo 'FAIL 未提示阻挡回滚的变更编号'; fail=1; }
[[ $(<"$SSHD_CONFIG") == 'newer ssh' && $(<"$PAM_SSHD") == 'newer pam' && $(<"$ACCESS_STATE") == active &&
   $(<"$VH_CHANGES/$old_ssh_id/status") == confirmed && ! -e $T/ssh-reloads ]] || { echo 'FAIL 拒绝回滚时修改了文件、状态或服务'; fail=1; }
change_status rollback_failed
change_rollback "$old_ssh_id" >/dev/null 2>&1 && { echo 'FAIL 较新的认证变更回滚不完整时允许覆盖'; fail=1; }
change_rollback "$new_ssh_id" >/dev/null && change_rollback "$old_ssh_id" >/dev/null || { echo 'FAIL 未允许按顺序回滚 SSH 变更'; fail=1; }
[[ $(<"$SSHD_CONFIG") == 'original ssh' && $(<"$PAM_SSHD") == 'original pam' && ! -e $ACCESS_STATE ]] || { echo 'FAIL 按顺序回滚未恢复原认证配置'; fail=1; }

# Closing root SSH can depend on a sudo grant without copying or rewriting its file.
SUDOERS_DIR="$T/sudoers.d"
mkdir "$SUDOERS_DIR"
grant="$SUDOERS_DIR/90-vhm-admin-alice"
change_begin '授予 alice sudo' >/dev/null
grant_id=$CHG_ID
change_track "$grant"
printf 'alice ALL=(ALL:ALL) PASSWD: ALL\n' >"$grant"
change_status applied
change_begin '验证 alice 后关闭 root SSH' sshd >/dev/null
root_close_id=$CHG_ID
change_track "$SSHD_CONFIG"
printf '%s\n' "$grant" >"$CHG_DIR/admin-required"
printf 'PermitRootLogin no\n' >"$SSHD_CONFIG"
change_status confirmed
change_rollback "$grant_id" >"$T/overlap-output" 2>&1 && { echo 'FAIL 允许先撤销唯一的 sudo 授权'; fail=1; }
[[ -f $grant ]] && grep -Fq "$root_close_id" "$T/overlap-output" || { echo 'FAIL 未保护或解释 sudo 授权依赖'; fail=1; }
change_rollback "$root_close_id" >/dev/null && [[ -f $grant && $(<"$SSHD_CONFIG") == 'original ssh' ]] &&
  change_rollback "$grant_id" >/dev/null && [[ ! -e $grant ]] || { echo 'FAIL 未恢复 SSH 后单独撤销 sudo'; fail=1; }

# Non-SSH history retains the previous manual overlap behavior.
printf 'original\n' >"$T/firewall.conf"
change_begin '旧防火墙变更' >/dev/null
old_firewall_id=$CHG_ID
change_track "$T/firewall.conf"
printf 'older\n' >"$T/firewall.conf"
change_status applied
change_begin '新防火墙变更' >/dev/null
change_track "$T/firewall.conf"
printf 'newer\n' >"$T/firewall.conf"
change_status applied
change_rollback "$old_firewall_id" >/dev/null || { echo 'FAIL 错误拦截了无关文件的手动回滚'; fail=1; }
[[ $(<"$T/firewall.conf") == original ]] || { echo 'FAIL 无关文件未恢复'; fail=1; }

((fail == 0)) && echo "PASS change-rollback"
exit $fail
