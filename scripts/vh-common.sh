#!/usr/bin/env bash
# 公共函数库：日志、交互、锁、脱敏、实例识别、变更记录与回滚、SSH/防火墙状态、vbm 备份、Vaultwarden 配置
# shellcheck disable=SC2034

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

# ---------- 日志 ----------
_log_file() {
  [[ -w "$(dirname "$VH_LOG")" ]] || return 0
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$(redact "$2")" >>"$VH_LOG" 2>/dev/null || true
}
log_info() { printf '%s[信息]%s %s\n' "$C_B" "$C_0" "$*"; _log_file INFO "$*"; }
log_ok() { printf '%s[完成]%s %s\n' "$C_G" "$C_0" "$*"; _log_file OK "$*"; }
log_warn() { printf '%s[注意]%s %s\n' "$C_Y" "$C_0" "$*" >&2; _log_file WARN "$*"; }
log_err() { printf '%s[错误]%s %s\n' "$C_R" "$C_0" "$*" >&2; _log_file ERROR "$*"; }
die() { log_err "$*"; exit 1; }
title() { printf '\n%s========== %s ==========%s\n' "$C_B" "$*" "$C_0"; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root 权限，请使用 sudo vhm"; }

# 各脚本都开启了 pipefail。「命令 | grep -q」中 grep 找到匹配会提前退出，前面的命令若还在输出就会收到
# SIGPIPE（退出码 141），整条管道被判为失败。需要按输出做判断时，先把输出存进变量再匹配。
out_match() { # out_match 扩展正则 命令...：命令的标准输出是否匹配
  local re=$1 out
  shift
  out=$("$@" 2>/dev/null) || true
  grep -Eq -- "$re" <<<"$out"
}

# 软件源域名（跳过注释行；兼容 sources.list 与 deb822 的 .sources，去掉账号和端口）
apt_host() {
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -r $f ]] && grep -Ev '^[[:space:]]*#' "$f"
  done 2>/dev/null | grep -Eo 'https?://[^/[:space:]]+' | sed -E -n '1{s#^https?://([^@/]*@)?##;s#:[0-9]+$##;p}'
}

apt_user_resolves() { # apt 下载时使用的 _apt 用户能否解析该域名
  id _apt >/dev/null 2>&1 || return 0
  runuser -u _apt -- getent hosts "$1" >/dev/null 2>&1
}

# apt_install 包...：失败时先 apt-get update 再重试；仍失败则判断原因：
# - root 也解析不了软件源域名 → DNS 不可用，给出修复步骤
# - root 能解析而 _apt 用户不能 → apt 沙箱读不到 DNS 配置，改用 root 身份下载再试一次
apt_install() {
  command -v apt-get >/dev/null 2>&1 || { log_err "未找到 apt-get，请手动安装：$*"; return 1; }
  local DEBIAN_FRONTEND=noninteractive host proxy rc
  export DEBIAN_FRONTEND
  apt-get install -y "$@" && return 0
  log_warn "安装失败，先更新软件源索引（apt-get update）再重试……"
  apt-get update && apt-get install -y "$@" && return 0
  host=$(apt_host)
  proxy=$(apt-config dump 2>/dev/null | grep -Ei '^Acquire::(https?|ftp)::Proxy ' || true)
  [[ -n $proxy ]] && log_warn "apt 配置了代理（$proxy），请确认代理可用"
  if [[ -z $host ]]; then
    log_err "安装 $* 失败（没有做任何修改），请查看上面 apt 的输出"
    return 1
  fi
  if ! getent hosts "$host" >/dev/null 2>&1; then
    log_err "无法解析软件源域名 $host：这台 VPS 当前的 DNS 不可用，所以装不了软件包（没有做任何修改）"
    echo "  1. 确认网络通：ping -c1 1.1.1.1" >&2
    echo "  2. 查看 DNS：resolvectl status（或 cat /etc/resolv.conf）" >&2
    echo "  3. 修复示例：在 /etc/systemd/resolved.conf 的 [Resolve] 下设置 DNS=1.1.1.1 8.8.8.8，然后 systemctl restart systemd-resolved" >&2
    echo "  修好后执行 getent hosts $host 能看到 IP，再回来重试。" >&2
    return 1
  fi
  if ! apt_user_resolves "$host"; then
    log_warn "root 能解析 $host，但 apt 下载时使用的 _apt 用户不能（常见原因：/etc/resolv.conf 或其指向的文件对其他用户不可读）"
    echo "  /etc/resolv.conf → $(readlink -f /etc/resolv.conf 2>/dev/null)（权限 $(stat -L -c '%a %U:%G' /etc/resolv.conf 2>/dev/null)）" >&2
    log_info "改用 root 身份下载，再试一次……"
    rc=0
    { apt-get -o APT::Sandbox::User=root update && apt-get -o APT::Sandbox::User=root install -y "$@"; } || rc=$?
    if ((rc == 0)); then
      log_ok "已安装 $*"
      local rf
      rf=$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)
      if [[ $(stat -L -c '%a' "$rf" 2>/dev/null) =~ [4-7]$ ]]; then
        log_info "$rf 权限正常，_apt 解析失败可能由 AppArmor 或按用户限制的出站规则造成；可用 runuser -u _apt -- getent hosts $host 排查"
      else
        log_warn "建议修复 DNS 配置文件权限：chmod 644 $rf"
      fi
      return 0
    fi
  fi
  log_err "安装 $* 失败（没有做任何修改）。root 能解析 $host，问题可能在代理、防火墙出站规则或软件源本身，请查看上面 apt 的输出"
  return 1
}

# ---------- 交互 ----------
pause() { [[ -t 0 ]] || return 0; read -r -p $'\n按 Enter 返回菜单... ' _ || true; }

read_default() { # read_default 提示 默认值
  local value
  read -r -p "$1 [$2]: " value || true
  printf '%s' "${value:-$2}"
}

# 风险确认：只有 yes（不区分大小写）才继续。
# - VH_ASSUME_YES=1：直接通过（仅供内部/测试使用）
# - 终端：提示后读取一行
# - 非终端（管道/重定向）：从标准输入读取一行；读不到（EOF）即取消
confirm_yes() {
  local prompt="${1:-确认继续？}" ans=""
  [[ "${VH_ASSUME_YES:-0}" == 1 ]] && return 0
  printf '\n%s\n' "$prompt"
  if [[ -t 0 ]]; then
    read -r -p "输入 yes 继续（其他输入均取消）: " ans || return 1
  else
    read -r ans || { log_warn "非交互输入为空，已取消"; return 1; }
  fi
  if [[ "${ans,,}" != yes ]]; then
    log_info "已取消"
    return 1
  fi
}

# ---------- 锁 ----------
# 互斥锁：冲突时以 75 退出，不删除他人锁。持锁后导出 VH_LOCK_HELD=1，子进程可重入。
with_lock() {
  if [[ "${VH_LOCK_HELD:-0}" == 1 ]]; then
    "$@"
    return
  fi
  mkdir -p "$(dirname "$VH_LOCK")" 2>/dev/null || true
  if ! exec 9>"$VH_LOCK"; then
    log_err "无法打开锁文件 $VH_LOCK"
    exit 1
  fi
  if ! flock -n 9; then
    log_warn "另一个 vhm 修改操作正在运行，请等它结束后再试（退出码 $VH_EXIT_LOCKED）"
    exit "$VH_EXIT_LOCKED"
  fi
  export VH_LOCK_HELD=1
  "$@"
}

# ---------- 脱敏 ----------
# 1. 键名以 TOKEN/PASSWORD/PASSWD/SECRET/KEY 结尾且紧跟 = 或 : 的值（不会命中 PasswordAuthentication=yes）
# 2. argon2 哈希
# 3. 40 位以上的随机串；不以 / 开头，因此绝对路径与 URL 路径不受影响
redact() {
  sed -E \
    -e 's/([A-Za-z0-9_]*(TOKEN|PASSWORD|PASSWD|SECRET|KEY)["]?[[:space:]]*[=:][[:space:]]*["]?)[^"[:space:],}]+/\1***REDACTED***/Ig' \
    -e 's/\$argon2[a-z]*\$[^[:space:]"]+/***ARGON2***/g' \
    -e 's#(^|[^A-Za-z0-9+/_-])[A-Za-z0-9+_-][A-Za-z0-9+/_-]{39,}#\1***LONG***#g' <<<"$*"
}

# ---------- 键值文件 ----------
conf_get() { # conf_get KEY [file]
  local f="${2:-$VH_CONF}"
  [[ -r "$f" ]] || return 1
  sed -nE "s/^[[:space:]]*$1=[\"']?([^\"']*)[\"']?[[:space:]]*$/\1/p" "$f" | tail -n1
}

kv_set() { # kv_set 文件 KEY 值（值只允许安全字符）
  local f=$1 k=$2 v=$3 tmp
  [[ $v =~ ^[A-Za-z0-9._,:/@\ -]*$ ]] || { log_err "非法值：$k"; return 1; }
  install -d -m 700 "$(dirname "$f")" || return 1
  tmp=$(mktemp "$f.XXXXXX") || return 1
  {
    [[ -f $f ]] && grep -v "^$k=" "$f"
    printf '%s="%s"\n' "$k" "$v"
  } >"$tmp"
  chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

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
    echo "vhm 仍会保存修改前的 config.json，可在菜单 [24] 回滚。"
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
    log_ok "$desc：已生效（变更 $CHG_ID，可在 [24] 回滚）"
  else
    log_err "$desc 失败，正在恢复原配置……"
    change_restore_files "$CHG_DIR"
    vw_restart_check || log_err "恢复后容器仍不健康，请在 1Panel 中检查 Vaultwarden 日志"
    change_status rolled_back
    rc=1
  fi
  vbm_lock_release
  return $rc
}

# ---------- 变更记录与回滚 ----------
# 目录：$VH_CHANGES/<YYYYmmdd-HHMMSS-PID>/
#   meta（ID/TIME/DESC/HOOKS）、status（pending/applied/rolled_back）
#   files.tsv（序号、修改前是否存在、权限、属主、路径），files/<序号> 为原文件副本
change_begin() { # change_begin 描述 [回滚钩子...]
  change_prune
  CHG_ID="$(date '+%Y%m%d-%H%M%S')-$$"
  # 同一进程同一秒内多次修改（如连续添加密钥）时避免记录目录重名
  while [[ -e "$VH_CHANGES/$CHG_ID" ]]; do
    sleep 1
    CHG_ID="$(date '+%Y%m%d-%H%M%S')-$$"
  done
  CHG_DIR="$VH_CHANGES/$CHG_ID"
  install -d -m 700 "$VH_STATE" "$VH_CHANGES" "$CHG_DIR" "$CHG_DIR/files" || die "无法创建变更记录目录"
  : >"$CHG_DIR/files.tsv"
  {
    printf 'ID=%s\n' "$CHG_ID"
    printf 'TIME=%s\n' "$(date '+%F %T')"
    printf 'DESC=%s\n' "${1//$'\n'/ }"
    printf 'HOOKS=%s\n' "${*:2}"
  } >"$CHG_DIR/meta"
  change_status pending
}

change_status() { printf '%s\n' "$1" >"$CHG_DIR/status"; }

change_track() { # 修改文件前调用；同一路径只记录一次
  local p=$1 n
  [[ -n "${CHG_DIR:-}" ]] || { log_err "内部错误：未开始变更记录"; return 1; }
  awk -F'\t' -v p="$p" '$5 == p { f = 1 } END { exit !f }' "$CHG_DIR/files.tsv" && return 0
  n=$(($(wc -l <"$CHG_DIR/files.tsv") + 1))
  if [[ -f "$p" ]]; then
    cp -a -- "$p" "$CHG_DIR/files/$n" || return 1
    printf '%s\t1\t%s\t%s\t%s\n' "$n" "$(stat -c %a "$p")" "$(stat -c %u:%g "$p")" "$p" >>"$CHG_DIR/files.tsv"
  elif [[ -e "$p" ]]; then
    log_err "$p 不是普通文件，拒绝修改"
    return 1
  else
    printf '%s\t0\t-\t-\t%s\n' "$n" "$p" >>"$CHG_DIR/files.tsv"
  fi
}

change_restore_files() { # change_restore_files 记录目录
  local d=$1 n ex mode own p rc=0
  while IFS=$'\t' read -r n ex mode own p; do
    [[ -n $p ]] || continue
    if [[ $ex == 1 ]]; then
      mkdir -p "$(dirname "$p")"
      { cp -a -- "$d/files/$n" "$p.vhm-restore" && mv -f -- "$p.vhm-restore" "$p"; } || { log_err "无法恢复 $p"; rc=1; }
    else
      rm -f -- "$p" || rc=1
    fi
  done <"$d/files.tsv"
  return $rc
}

change_meta() { sed -n "s/^$2=//p" "$VH_CHANGES/$1/meta" 2>/dev/null; } # change_meta ID KEY

# ---------- 变更记录清理 ----------
# 自动保留：最近 CHANGES_KEEP 条 + 最近 CHANGES_KEEP_DAYS 天内的全部记录，其余在下次修改前自动删除。
# 正在防锁死保护中、或一小时内创建且未完成的记录永远不会被删除。
CHANGES_KEEP=${CHANGES_KEEP:-50}
CHANGES_KEEP_DAYS=${CHANGES_KEEP_DAYS:-90}

change_ids() { # 从新到旧
  find "$VH_CHANGES" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
    grep -E '^[0-9]{8}-[0-9]{6}-[0-9]+$' | sort -r
}

change_protected() { # 0=受保护（不能删）
  local id=$1 d="$VH_CHANGES/$1"
  systemctl is-active --quiet "vhm-guard-$id.timer" 2>/dev/null && return 0
  [[ $(cat "$d/status" 2>/dev/null) == pending && -n $(find "$d" -maxdepth 0 -mmin -60 2>/dev/null) ]] && return 0
  return 1
}

change_delete() {
  local id=$1
  [[ $id =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ && -d $VH_CHANGES/$id ]] || return 1
  change_protected "$id" && return 1
  rm -rf -- "${VH_CHANGES:?}/$id"
}

change_prune() {
  local cutoff n=0 id
  [[ -d $VH_CHANGES ]] || return 0
  cutoff=$(date -d "-$CHANGES_KEEP_DAYS days" '+%Y%m%d' 2>/dev/null) || return 0
  while IFS= read -r id; do
    n=$((n + 1))
    ((n <= CHANGES_KEEP)) && continue
    [[ ${id:0:8} > "$cutoff" || ${id:0:8} == "$cutoff" ]] && continue
    change_delete "$id" || true
  done < <(change_ids)
  return 0
}

# 1Panel 面板变更的回滚：记录目录中的 panel.prev 保存修改前的端口与监听方式
panel_restore() {
  local d=$1 port listen cur
  [[ -f $d/panel.prev ]] || return 0
  port=$(conf_get PORT "$d/panel.prev" || true)
  listen=$(conf_get LISTEN "$d/panel.prev" || true)
  if [[ -n $listen ]]; then
    panel_listen "$listen" >/dev/null || return 1
  fi
  if [[ -n $port ]]; then
    cur=$(panel_port_of "$(panel_url)")
    [[ $cur == "$port" ]] || panel_set_port "$port" >/dev/null || return 1
  fi
}

run_hooks() { # run_hooks 记录目录 钩子...
  local d=$1 h rc=0
  shift
  for h in "$@"; do
    case $h in
      sshd) ssh_reload || rc=1 ;;
      fail2ban) f2b_reload || rc=1 ;;
      sysctl) sysctl_restore "$d" || rc=1 ;;
      vw) vw_restart_check || rc=1 ;;
      panel) panel_restore "$d" || rc=1 ;;
    esac
  done
  return $rc
}

# 回滚一条变更；按记录加锁，重复调用无副作用（守护定时器与前台可能同时触发）
change_rollback() {
  local id=$1 d="$VH_CHANGES/$1" st hooks rc=0
  [[ $id =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ && -d $d ]] || { log_err "找不到变更记录：$id"; return 1; }
  exec 7>"$d/.lock" || return 1
  flock -w 60 7 || { log_err "变更 $id 正在被处理"; exec 7>&-; return 1; }
  st=$(cat "$d/status" 2>/dev/null)
  if [[ $st == rolled_back ]]; then
    log_info "变更 $id 已经回滚过"
    exec 7>&-
    return 0
  fi
  hooks=$(change_meta "$id" HOOKS)
  change_restore_files "$d" || rc=1
  # shellcheck disable=SC2086
  run_hooks "$d" $hooks || rc=1
  printf 'rolled_back\n' >"$d/status"
  exec 7>&-
  if ((rc == 0)); then log_ok "已回滚变更 $id（$(change_meta "$id" DESC)）"; else log_err "变更 $id 回滚时出现错误，请检查上面的输出"; fi
  return $rc
}

# SSH 类变更的防锁死保护：到时未确认则由 systemd 定时器自动回滚（当前会话不受影响）
guard_start() {
  command -v systemd-run >/dev/null 2>&1 || { log_err "缺少 systemd-run，无法设置自动回滚保护"; return 1; }
  systemd-run --quiet --unit="vhm-guard-$CHG_ID" --on-active="$GUARD_SECONDS" --timer-property=AccuracySec=1s \
    --setenv=VH_CONF="$VH_CONF" --setenv=VH_STATE="$VH_STATE" --setenv=VH_LOG="$VH_LOG" \
    /bin/bash "$VH_DIR/vh-changes.sh" auto-rollback "$CHG_ID"
}
guard_stop() { systemctl stop "vhm-guard-$CHG_ID.timer" >/dev/null 2>&1 || true; }

# 返回 0 表示用户确认保留；否则已回滚
guard_wait_confirm() {
  local ans="" mins=$((GUARD_SECONDS / 60))
  echo
  printf '%s已启用 %s 分钟自动回滚保护。%s\n' "$C_Y" "$mins" "$C_0"
  echo "请【保持当前窗口不要关闭】，另开一个终端窗口按新方式登录服务器。"
  [[ -n ${1:-} ]] && echo "测试命令：$1"
  echo "登录成功后回到这里输入 yes 保留更改；输入其他内容会立即回滚；${mins} 分钟内无操作将自动回滚。"
  if read -r -t "$GUARD_SECONDS" -p "新窗口登录成功了吗？输入 yes 保留: " ans && [[ ${ans,,} == yes ]]; then
    guard_stop
    if [[ $(cat "$CHG_DIR/status" 2>/dev/null) == rolled_back ]]; then
      log_err "确认太晚，已经自动回滚。"
      return 1
    fi
    return 0
  fi
  echo
  guard_stop
  log_warn "未确认，正在回滚……"
  change_rollback "$CHG_ID"
  return 1
}

# ---------- SSH ----------
if [[ -z ${SSHD_BIN:-} ]]; then
  if [[ -x /usr/sbin/sshd ]]; then SSHD_BIN=/usr/sbin/sshd; else SSHD_BIN=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd); fi
fi
sshd_test() { mkdir -p /run/sshd 2>/dev/null; "$SSHD_BIN" -t 2>&1; }
# 生效配置：优先按「root 从外网登录」的条件计算（让 Match 块生效）；不支持 -C 时退回 sshd -T
sshd_eff() {
  local out
  mkdir -p /run/sshd 2>/dev/null
  out=$("$SSHD_BIN" -T -C user=root,host=vhm-check,addr=203.0.113.1 2>/dev/null) || out=""
  [[ -n $out ]] || out=$("$SSHD_BIN" -T 2>/dev/null) || out=""
  [[ -n $out ]] && printf '%s\n' "$out"
}
sshd_eff_err() { mkdir -p /run/sshd 2>/dev/null; "$SSHD_BIN" -T 2>&1 >/dev/null | tail -n 3; }
sshd_get() { sshd_eff | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }'; }
ssh_service() { if systemctl cat ssh.service >/dev/null 2>&1; then echo ssh; else echo sshd; fi; }
ssh_socket_used() { systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; }

ssh_reload() {
  local out svc
  out=$(sshd_test) || { log_err "sshd 配置检查未通过：$out"; return 1; }
  svc=$(ssh_service)
  if ssh_socket_used; then
    systemctl daemon-reload || return 1
    systemctl restart ssh.socket || return 1
    systemctl try-restart "$svc" || return 1
  elif systemctl is-active --quiet "$svc"; then
    systemctl reload "$svc" || systemctl restart "$svc" || return 1
  else
    systemctl start "$svc" || return 1
  fi
}

tfa_pam_on() { grep -Eq '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_google_authenticator\.so' "$PAM_SSHD" 2>/dev/null; }
tfa_enabled() { tfa_pam_on && [[ $(sshd_get authenticationmethods) == *publickey,keyboard-interactive* ]]; }

# ---------- 防火墙 / Fail2Ban / sysctl ----------
# 防火墙规则由 1Panel 管理，vhm 只读识别。1Panel（iptables）使用 1PANEL_BASIC_BEFORE / 1PANEL_BASIC /
# 1PANEL_BASIC_AFTER 三条链挂在 INPUT 上，放行规则在 1PANEL_BASIC，末尾链默认丢弃其余 TCP/UDP。
fw_type() {
  if command -v ufw >/dev/null 2>&1 && out_match 'Status: active' ufw status; then
    echo ufw
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo firewalld
  elif command -v iptables >/dev/null 2>&1 && out_match '-j 1PANEL_BASIC' iptables -w -S INPUT; then
    echo 1panel-iptables
  elif command -v nft >/dev/null 2>&1 && out_match '1panel|1PANEL' nft list ruleset; then
    echo 1panel-nftables
  elif command -v nft >/dev/null 2>&1 && out_match 'hook input .*policy drop' nft list ruleset; then
    echo nftables
  elif command -v iptables >/dev/null 2>&1 && out_match '^-P INPUT DROP' iptables -w -S INPUT; then
    echo iptables
  else
    echo none
  fi
}

# shellcheck disable=SC2120 # 参数可选，默认读取当前防火墙类型
fw_label() {
  case ${1:-$(fw_type)} in
    1panel-iptables) echo "1Panel（iptables）" ;;
    1panel-nftables) echo "1Panel（nftables）" ;;
    none) echo "未启用" ;;
    *) echo "$1" ;;
  esac
}

# port_scope 端口 [tcp|udp]：主机防火墙对该端口的放行范围
# 输出 all（所有 IP）/ limited（仅指定 IP）/ none（未放行）/ unknown（无法判断）
port_scope() {
  local p=$1 proto=${2:-tcp} rules
  case $(fw_type) in
    none) echo all ;;
    ufw)
      rules=$(ufw status 2>/dev/null | grep -E "^$p(/$proto)?[[:space:]]" | grep ALLOW || true)
      if [[ -z $rules ]]; then echo none; elif grep -q 'ALLOW.*Anywhere' <<<"$rules"; then echo all; else echo limited; fi
      ;;
    firewalld)
      if out_match "(^| )$p/$proto( |$)" firewall-cmd --list-ports; then
        echo all
      elif [[ $p == 22 && $proto == tcp ]] && out_match '(^| )ssh( |$)' firewall-cmd --list-services; then
        echo all
      elif out_match "port=\"$p\" protocol=\"$proto\"" firewall-cmd --list-rich-rules; then
        echo limited
      else
        echo none
      fi
      ;;
    1panel-iptables)
      rules=$(iptables -w -S 1PANEL_BASIC 2>/dev/null | grep -E -- "-p $proto .*--dports? ([0-9,]*,)?$p(,| |$)" | grep -- '-j ACCEPT' || true)
      if [[ -z $rules ]]; then echo none; elif grep -qv -- ' -s ' <<<"$rules"; then echo all; else echo limited; fi
      ;;
    *) echo unknown ;;
  esac
}

port_allowed() { # 0=已放行 1=未放行 2=无法判断
  case $(port_scope "$1" "${2:-tcp}") in
    all | limited) return 0 ;;
    none) return 1 ;;
    *) return 2 ;;
  esac
}

# 修改端口前确认防火墙已放行；未放行时提示到 1Panel 放行
wait_port_allowed() {
  local p=$1 rc a
  while true; do
    rc=0
    port_allowed "$p" || rc=$?
    case $rc in
      0) log_ok "防火墙已放行 $p/tcp"; return 0 ;;
      2)
        log_warn "当前防火墙是 $(fw_label)，无法自动判断 $p/tcp 是否已放行"
        confirm_yes "确认已放行 $p/tcp？" && return 0
        return 1
        ;;
    esac
    log_warn "防火墙尚未放行 $p/tcp。请到 1Panel →「主机」→「防火墙」→「创建规则」，放行端口 $p，协议 TCP。"
    echo "云服务器还要在服务商控制台的安全组里放行。"
    read -r -p "放行后按 Enter 重新检查；输入 y 跳过检查（已用端口范围放行时）；输入 q 取消: " a || return 1
    case $a in
      q | Q) return 1 ;;
      y | Y) return 0 ;;
    esac
  done
}

# 1Panel v2 的 Docker 端口访问控制（docker_guard）：nftables 表 nft_1panel_docker 或 iptables 链 1PANEL_DOCKER*
docker_guard_on() {
  { command -v nft >/dev/null 2>&1 && out_match nft_1panel_docker nft list tables; } ||
    { command -v iptables >/dev/null 2>&1 && out_match 1PANEL_DOCKER iptables -w -S; }
}

# ---------- 1Panel ----------
panel_installed() { command -v 1pctl >/dev/null 2>&1; }
panel_version() {
  local out
  out=$(timeout 20 1pctl version 2>/dev/null) || true
  grep -m1 -Eo 'v[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*' <<<"$out"
}
panel_units() { # v2 为 1panel-core / 1panel-agent，v1 为 1panel
  local u
  for u in 1panel-core 1panel-agent 1panel; do
    systemctl cat "$u.service" >/dev/null 2>&1 && echo "$u"
  done
  return 0
}
panel_active() {
  local u
  u=$(panel_units | head -n1)
  [[ -n $u ]] && systemctl is-active --quiet "$u"
}
panel_url() {
  local out
  out=$(timeout 20 1pctl user-info 2>/dev/null) || true
  grep -m1 -Eo 'https?://[^[:space:]]+' <<<"$out"
}
# 当前 1pctl reset 帮助中列出的子命令（空格分隔）。1pctl reset 不带参数时由 1panel 打印帮助
reset_available() {
  local out
  out=$(timeout 20 1pctl reset 2>&1) || true
  sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | awk '/^[[:space:]]+[a-z]+[[:space:]]/ { printf "%s ", $1 }'
}
panel_port_of() { sed -nE 's#^https?://[^/]*:([0-9]+)(/.*)?$#\1#p' <<<"$1"; }
panel_entrance_of() { sed -nE 's#^https?://[^/]*:[0-9]+/?([^[:space:]]*)$#\1#p' <<<"$1"; }
panel_wait_port() { # 最多等待 40 秒，直到端口在监听
  local i
  for ((i = 0; i < 40; i++)); do
    [[ -n $(ss -ltnH "sport = :$1" 2>/dev/null) ]] && return 0
    sleep 1
  done
  return 1
}
panel_set_port() { # 1pctl update port 从标准输入读取新端口，修改后自动重启面板
  printf '%s\n' "$1" | timeout 90 1pctl update port || return 1
  panel_wait_port "$1"
}
panel_restart_core() {
  local u
  u=$(panel_units | head -n1)
  [[ -n $u ]] || return 1
  systemctl restart "$u"
}
panel_listen() { # ipv4 | ipv6
  [[ $1 == ipv4 || $1 == ipv6 ]] || return 1
  timeout 60 1pctl listen-ip "$1" && panel_restart_core
}

f2b_reload() {
  command -v fail2ban-client >/dev/null 2>&1 || return 0
  systemctl restart fail2ban
}

f2b_banned() { fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ { gsub(/[[:space:]]/, "", $2); print $2 }'; }

sysctl_restore() { # 恢复修改前记录的运行时参数
  local d=$1 k v
  [[ -f $d/sysctl.prev ]] || return 0
  while IFS='=' read -r k v; do
    [[ -n $k ]] && sysctl -q -w "$k=$v" >/dev/null
  done <"$d/sysctl.prev"
}

# ---------- 旧版清理 ----------
# v0.1.x 的定时巡检与后台脚本副本已移除；升级后首次运行时清理
vh_legacy_cleanup() {
  local u found=0 old=/usr/local/lib/vaultwarden-hardening
  for u in vaultwarden-hardening-watch.timer vaultwarden-hardening-watch.service; do
    if [[ -f /etc/systemd/system/$u ]]; then
      found=1
      systemctl disable --now "$u" >/dev/null 2>&1 || true
      rm -f -- "/etc/systemd/system/$u"
    fi
  done
  if ((found)); then
    systemctl daemon-reload || true
    log_info "已移除 v0.1.x 的定时巡检（vaultwarden-hardening-watch）"
  fi
  if [[ -d $old/scripts && ! -L $old ]]; then
    rm -rf -- "$old" && log_info "已移除 v0.1.x 的后台脚本副本 $old"
  fi
  return 0
}
