#!/usr/bin/env bash
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export VH_LOG=/dev/null VH_STATE="$T/state" VBM_CONF="$T/vbm.conf" VBM_WORKER="$T/worker.sh" VBM_RUNS="$T/runs" VBM_LOCK="$T/vbm.lock"
VW_DATA_DIR="$T/selected"
mkdir -p "$VW_DATA_DIR" "$T/other" "$VBM_RUNS" || exit 1
cat >"$VBM_WORKER" <<'SH'
#!/usr/bin/env bash
[[ $1 == webdav ]] || exit 1
printf 'called\n' >>"$VBM_RUNS/calls"
printf '%s\n' STATUS=success "RUN_ID=$VW_RUN_ID" LOCAL_VERIFIED=true SERVICE_RESTORED=true REMOTE_VERIFIED=true >"$VBM_RUNS/$VW_RUN_ID.env"
SH
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
fail=0

for data_dir in '' "$T/missing" "$T/other"; do
  printf 'BACKUP_TARGET="webdav"\nVW_DATA_DIR="%s"\n' "$data_dir" >"$VBM_CONF"
  vbm_backup_before_change >/dev/null 2>&1 && { echo "FAIL 未拒绝无法确认的备份目录：$data_dir"; fail=1; }
done
[[ ! -e $VBM_RUNS/calls ]] || { echo "FAIL 备份目标不匹配时启动了备份"; fail=1; }

printf 'BACKUP_TARGET="webdav"\nVW_DATA_DIR="%s/."\n' "$VW_DATA_DIR" >"$VBM_CONF"
vbm_backup_before_change >/dev/null || { echo "FAIL 同一备份目录未通过校验"; fail=1; }
[[ $(cat "$VBM_RUNS/calls" 2>/dev/null) == called ]] || { echo "FAIL 同一备份目录没有执行一次备份"; fail=1; }

flock() {
  if [[ $# == 3 && $1 == -w && $2 == 30 && $3 == 8 ]]; then
    command flock -n 8
  else
    command flock "$@"
  fi
}

selected_data=$VW_DATA_DIR
load_instance() { VW_DATA_DIR=$selected_data VW_CONTAINER=fixture; }
vw_restart_check() {
  printf '%s\n' "$VW_DATA_DIR" >>"$T/restarts"
  if command flock -n "$VBM_LOCK" true; then
    echo "FAIL 重启 Vaultwarden 时未持有 vbm 锁"
    return 1
  fi
  [[ $(vw_cfg signups_allowed) == true ]]
}

config_file="$VW_DATA_DIR/config.json"
printf '{"signups_allowed": true}\n' >"$config_file"
change_begin "手动回滚测试" vw || exit 1
change_track "$config_file" || exit 1
printf '{"signups_allowed": false}\n' >"$config_file"
change_status applied || exit 1
{
  command flock -n 6 || exit 1
  change_rollback "$CHG_ID" >/dev/null 2>&1 && { echo "FAIL 备份进行时允许了手动回滚"; fail=1; }
} 6>"$VBM_LOCK"
[[ $(vw_cfg signups_allowed) == false && $(cat "$CHG_DIR/status") == applied ]] || { echo "FAIL 锁被占用时改动了配置或记录"; fail=1; }
selected_data="$T/other"
printf '{"signups_allowed": true}\n' >"$selected_data/config.json"
change_rollback "$CHG_ID" >/dev/null 2>&1 && { echo "FAIL 允许回滚其他 Vaultwarden 实例的记录"; fail=1; }
[[ $(vw_cfg signups_allowed) == false && $(cat "$CHG_DIR/status") == applied && ! -e $T/restarts ]] || { echo "FAIL 实例不匹配时修改了配置或记录，或重启了容器"; fail=1; }
command flock -n "$VBM_LOCK" true || { echo "FAIL 拒绝回滚后仍持有 vbm 锁"; fail=1; }
selected_data="$VW_DATA_DIR/."
mv -- "$config_file" "$T/previous-config" || exit 1
change_rollback "$CHG_ID" >/dev/null || { echo "FAIL 相同数据目录的手动回滚失败"; fail=1; }
[[ $(vw_cfg signups_allowed) == true && $(cat "$CHG_DIR/status") == rolled_back ]] || { echo "FAIL 手动回滚未恢复原设置"; fail=1; }
command flock -n "$VBM_LOCK" true || { echo "FAIL 手动回滚结束后仍持有 vbm 锁"; fail=1; }

(
  vw_apply "自动回滚测试" $'signups_allowed\tfalse' >/dev/null && exit 1
  [[ $(vw_cfg signups_allowed) == true && $(cat "$CHG_DIR/status") == rolled_back ]] || exit 1
  command flock -n "$VBM_LOCK" true || exit 1
  printf 'stderr remains open\n' >&2
) 2>"$T/diagnostics" || { echo "FAIL 自动回滚未复用并释放 vbm 锁"; fail=1; }
grep -Fxq 'stderr remains open' "$T/diagnostics" || { echo "FAIL 释放备份锁后标准错误被重定向"; fail=1; }

((fail == 0)) && echo "PASS vbm-backup"
exit "$fail"
