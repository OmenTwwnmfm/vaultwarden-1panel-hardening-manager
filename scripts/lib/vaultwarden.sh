# shellcheck shell=bash
# shellcheck disable=SC2034
# Vaultwarden 实例识别、配置读写与 vbm 备份联动；由 vh-common.sh 加载，不要单独执行

# ---------- Vaultwarden 实例 ----------
# 敏感路径：数据目录本身及其中含秘密/数据的文件与子目录（仅输出存在的）
vw_sensitive_paths() {
  local d=${1:-${VW_DATA_DIR:-}} p
  [[ -n "$d" && -d "$d" ]] || return 0
  printf '%s\n' "$d"
  for p in "$d"/db.sqlite3 "$d"/db.sqlite3-wal "$d"/db.sqlite3-shm "$d"/rsa_key* \
    "$d"/config.json "$d"/attachments "$d"/sends; do
    [[ -e "$p" ]] && printf '%s\n' "$p"
  done
  return 0
}

# 实例识别：以 /data 主机挂载路径作为身份；多候选或缺失即停止
detect_instance() {
  local from_vbm want=${1:-}
  from_vbm=$(conf_get VW_DATA_DIR "$VBM_CONF" 2>/dev/null || true)
  [[ -n $want ]] && from_vbm=$want
  local ids=()
  mapfile -t ids < <(docker ps -a --format '{{.ID}}' 2>/dev/null)
  local cands=() id src name img
  for id in "${ids[@]}"; do
    src=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$id" 2>/dev/null)
    [[ -n "$src" ]] || continue
    img=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null)
    [[ ${img,,} == *vaultwarden* ]] || continue
    name=$(docker inspect -f '{{.Name}}' "$id")
    name=${name#/}
    cands+=("$name|$src")
  done
  if [[ -n "$from_vbm" ]]; then
    local c
    for c in "${cands[@]}"; do
      if [[ "${c#*|}" == "$from_vbm" ]]; then
        VW_CONTAINER=${c%%|*}
        VW_DATA_DIR=$from_vbm
        return 0
      fi
    done
    log_err "数据目录 $from_vbm 未找到对应容器，停止（不猜测）"
    return 2
  fi
  case ${#cands[@]} in
    0) log_err "未发现挂载 /data 的 Vaultwarden 容器"; return 2 ;;
    1) VW_CONTAINER=${cands[0]%%|*}; VW_DATA_DIR=${cands[0]#*|}; return 0 ;;
    *) log_err "发现多个候选实例，请在 $VH_CONF 中指定 VW_DATA_DIR："; printf '  %s\n' "${cands[@]}" >&2; return 2 ;;
  esac
}

load_instance() {
  VW_DATA_DIR=$(conf_get VW_DATA_DIR || true)
  VW_CONTAINER=$(conf_get VW_CONTAINER || true)
  if [[ -z "$VW_DATA_DIR" ]]; then
    detect_instance || return $?
  elif [[ ! -d "$VW_DATA_DIR" ]]; then
    log_err "已确认的数据目录 $VW_DATA_DIR 不存在，停止"
    return 2
  elif [[ -z "$VW_CONTAINER" ]] || ! docker inspect "$VW_CONTAINER" >/dev/null 2>&1; then
    # 1Panel 重建应用后容器名可能变化：按数据目录重新匹配
    detect_instance "$VW_DATA_DIR" || return $?
  else
    # 已保存的配对也要复检挂载关系：容器名可能被其他应用复用，
    # 若它没有把该目录挂载为 /data，按数据目录重新识别而不是直接信任。
    local mounted
    mounted=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$VW_CONTAINER" 2>/dev/null)
    if [[ "$mounted" != "$VW_DATA_DIR" ]]; then
      log_warn "已保存的容器 $VW_CONTAINER 未把 $VW_DATA_DIR 挂载为 /data，按数据目录重新识别"
      detect_instance "$VW_DATA_DIR" || return $?
    fi
  fi
}

vw_env() { # 读取容器环境变量（只读）
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$VW_CONTAINER" 2>/dev/null |
    sed -nE "s/^$1=(.*)$/\1/p" | tail -n1
}

vw_cfg() { # 读取 /data/config.json 键（/admin 保存的设置，优先于环境变量）
  local f="$VW_DATA_DIR/config.json"
  [[ -r "$f" ]] || return 0
  python3 - "$f" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2])
except Exception:
    sys.exit(0)
if v is not None:
    print(str(v).lower() if isinstance(v, bool) else v)
PY
}

vw_cfg_has() { # config.json 中是否存在该键（值可为空串）
  local f="$VW_DATA_DIR/config.json"
  [[ -r "$f" ]] || return 1
  python3 - "$f" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1], encoding="utf-8")) else 1)
except Exception:
    sys.exit(1)
PY
}

vw_eff() { # 有效值：config.json > 环境变量 > 默认
  local k_cfg=$1 k_env=$2 def=$3 v
  v=$(vw_cfg "$k_cfg"); [[ -n "$v" ]] && { echo "$v"; return; }
  v=$(vw_env "$k_env"); [[ -n "$v" ]] && { echo "${v,,}"; return; }
  echo "$def"
}

vw_src() { # 有效值来源：config.json / 环境变量 / 默认值
  if vw_cfg_has "$1"; then echo config.json; elif [[ -n $(vw_env "$2") ]]; then echo 环境变量; else echo 默认值; fi
}

# 后台令牌状态：off（关闭）/ notoken（免令牌，危险）/ argon2 / plain
vw_admin_state() {
  local tok
  if [[ $(vw_eff disable_admin_token DISABLE_ADMIN_TOKEN false) == true ]]; then
    echo notoken
    return
  fi
  if vw_cfg_has admin_token; then tok=$(vw_cfg admin_token); else tok=$(vw_env ADMIN_TOKEN); fi
  tok=${tok//[[:space:]]/}
  if [[ -z $tok ]]; then echo off; elif [[ $tok == '$argon2'* ]]; then echo argon2; else echo plain; fi
}

vw_health_wait() { # 最多等待 120 秒，直到容器 healthy（无健康检查时执行 /healthcheck.sh）
  local i st
  for ((i = 0; i < 60; i++)); do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$VW_CONTAINER" 2>/dev/null || true)
    case $st in
      healthy) return 0 ;;
      running) docker exec "$VW_CONTAINER" /healthcheck.sh >/dev/null 2>&1 && return 0 ;;
    esac
    sleep 2
  done
  return 1
}

vw_restart_check() {
  load_instance >/dev/null 2>&1 || load_instance || return 1
  log_info "重启容器 $VW_CONTAINER 并等待健康检查……"
  docker restart "$VW_CONTAINER" >/dev/null || return 1
  vw_health_wait
}

# 写入 config.json：标准输入每行「键<TAB>JSON 值」，值为 __DELETE__ 时删除该键。
# 原子替换，权限 600，属主沿用原文件或数据目录。
# 注意：python3 的脚本本身来自 heredoc（占用标准输入），所以更新内容经环境变量传入，
# 不放在命令行参数里（避免哈希出现在 ps 中）。
vw_config_write() {
  local updates
  updates=$(cat)
  VH_UPDATES="$updates" python3 - "$VW_DATA_DIR/config.json" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
data = {}
try:
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            raise ValueError("顶层不是 JSON 对象")
        st = os.stat(path)
    else:
        st = os.stat(os.path.dirname(path))
except (OSError, ValueError) as exc:
    sys.exit(f"[错误] 无法读取 {path}：{exc}")
for line in os.environ.get("VH_UPDATES", "").splitlines():
    if not line.strip():
        continue
    key, _, raw = line.partition("\t")
    if raw == "__DELETE__":
        data.pop(key, None)
    else:
        try:
            data[key] = json.loads(raw)
        except ValueError:
            sys.exit(f"[错误] {key} 的值不是合法 JSON")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".config.json.")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.chmod(tmp, 0o600)
try:
    os.chown(tmp, st.st_uid, st.st_gid)
except PermissionError:
    pass
os.replace(tmp, path)
PY
}

# ---------- vbm 备份 ----------
vbm_installed() { [[ -f "$VBM_CONF" && -f "$VBM_WORKER" ]]; }

# 修改 Vaultwarden 前调用 vbm 完整备份；本地校验、服务恢复、远端核验全部通过才返回 0
vbm_backup_before_change() {
  if ! vbm_installed; then
    log_warn "未检测到 vbm（$VBM_WORKER），修改前无法做完整备份。"
    echo "vhm 仍会保存修改前的 config.json，可在菜单 [25] 回滚。"
    confirm_yes "在没有完整备份的情况下继续修改？" || return 1
    return 0
  fi
  local target run_id result rc=0 k
  target=$(conf_get BACKUP_TARGET "$VBM_CONF" || true)
  [[ $target == github || $target == webdav ]] || { log_err "无法从 $VBM_CONF 读取备份目标，未修改"; return 1; }
  run_id="vhm-$(date '+%Y%m%d-%H%M%S')-$$"
  result="$VBM_RUNS/$run_id.env"
  log_info "修改前先调用 vbm 完整备份（目标：$target），Vaultwarden 会短暂停止……"
  VW_RUN_ID="$run_id" bash "$VBM_WORKER" "$target" || rc=$?
  if ((rc == 75)); then
    log_err "vbm 正在执行定时备份或恢复，本次未修改。请等它结束后重试。"
    return 1
  fi
  if ((rc == 0)) && [[ -f $result ]]; then
    for k in STATUS=success "RUN_ID=$run_id" LOCAL_VERIFIED=true SERVICE_RESTORED=true REMOTE_VERIFIED=true; do
      grep -Fxq "$k" "$result" || { rc=1; break; }
    done
    if ((rc == 0)); then
      log_ok "vbm 备份成功并通过远端核验（运行 ID：$run_id）"
      return 0
    fi
  fi
  log_err "vbm 备份未通过校验（退出码 $rc），本次未修改。请查看 /var/log/vaultwarden-backup.log"
  return 1
}

# 修改期间持有 vbm 的锁，避免定时备份在重启容器时介入（vbm 会以 75 跳过）
vbm_lock_hold() {
  [[ -e $VBM_CONF ]] || return 0
  mkdir -p "$(dirname "$VBM_LOCK")" 2>/dev/null || true
  [[ ! -L "$VBM_LOCK" ]] || { log_err "vbm 锁文件是符号链接，拒绝使用：$VBM_LOCK"; return 1; }
  exec 8>"$VBM_LOCK" || return 1
  flock -w 30 8 || { log_err "vbm 的锁被占用，本次未修改"; exec 8>&-; return 1; }
}
vbm_lock_release() { exec 8>&- 2>/dev/null || true; }

# vw_apply 描述 更新行（格式见 vw_config_write）。更新内容按参数传入，保证标准输入仍是终端，
# 以便 vbm 未安装时还能交互确认。
# 流程：vbm 备份 → 记录 config.json → 写入 → 重启 → 健康检查；失败自动回滚。
vw_apply() {
  local desc=$1 updates=$2 rc=0
  load_instance || return 1
  vbm_backup_before_change || return 1
  vbm_lock_hold || return 1
  change_begin "$desc" vw
  change_track "$VW_DATA_DIR/config.json" || rc=1
  if ((rc == 0)) && ! printf '%s\n' "$updates" | vw_config_write; then rc=1; fi
  if ((rc == 0)) && vw_restart_check; then
    change_status applied
    log_ok "$desc：已生效（变更 $CHG_ID，可在 [25] 回滚）"
  else
    log_err "$desc 失败，正在恢复原配置……"
    change_rollback "$CHG_ID" || log_err "恢复失败，记录已标记为「回滚失败」，可在 [25] 重试"
    rc=1
  fi
  vbm_lock_release
  return $rc
}
