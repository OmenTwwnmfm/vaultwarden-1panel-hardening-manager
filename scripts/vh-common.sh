#!/usr/bin/env bash
# 公共函数库：日志、确认、锁、脱敏、实例识别、敏感路径
# shellcheck disable=SC2034

VH_VERSION="$(cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION" 2>/dev/null || echo unknown)"
VH_CONF=${VH_CONF:-/etc/vaultwarden-hardening.conf}
VH_STATE=${VH_STATE:-/var/lib/vaultwarden-hardening}
VH_LOG=${VH_LOG:-/var/log/vaultwarden-hardening.log}
VH_LOCK=${VH_LOCK:-/run/lock/vaultwarden-hardening.lock}
VBM_CONF=${VBM_CONF:-/etc/vaultwarden-backup.conf}
VH_EXIT_LOCKED=75

if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[36m' C_0=$'\e[0m'
else
  C_R='' C_G='' C_Y='' C_B='' C_0=''
fi

_log_file() {
  [[ -w "$(dirname "$VH_LOG")" ]] || return 0
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$(redact "$2")" >>"$VH_LOG" 2>/dev/null || true
}
log_info() { printf '%s[信息]%s %s\n' "$C_B" "$C_0" "$*"; _log_file INFO "$*"; }
log_ok() { printf '%s[完成]%s %s\n' "$C_G" "$C_0" "$*"; _log_file OK "$*"; }
log_warn() { printf '%s[警告]%s %s\n' "$C_Y" "$C_0" "$*" >&2; _log_file WARN "$*"; }
log_err() { printf '%s[错误]%s %s\n' "$C_R" "$C_0" "$*" >&2; _log_file ERROR "$*"; }
die() { log_err "$*"; exit 1; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root 权限，请使用 sudo vhm"; }

# 风险确认：只有 yes（不区分大小写）才继续。
# - VH_ASSUME_YES=1：直接通过（仅供内部/测试使用）
# - 终端：提示后读取一行
# - 非终端（管道/重定向）：从标准输入读取一行；读不到（EOF）即取消
confirm_yes() {
  local prompt="${1:-确认继续？}" ans=""
  [[ "${VH_ASSUME_YES:-0}" == 1 ]] && return 0
  if [[ -t 0 ]]; then
    read -r -p "$prompt 输入 yes 继续：" ans || return 1
  else
    read -r ans || { log_warn "非交互输入为空，已取消"; return 1; }
  fi
  if [[ "${ans,,}" != yes ]]; then
    log_info "已取消"
    return 1
  fi
}

# 互斥锁：冲突时以 75 退出，不删除他人锁。
# 持锁后导出 VH_LOCK_HELD=1，子进程（如巡检调用审计、应用调用回滚）可重入。
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
    log_warn "另一个 vhm 任务正在运行，跳过本次（退出码 $VH_EXIT_LOCKED）"
    exit "$VH_EXIT_LOCKED"
  fi
  export VH_LOCK_HELD=1
  "$@"
}

# 脱敏：
# 1. 键名以 TOKEN/PASSWORD/PASSWD/SECRET/KEY 结尾且紧跟 = 或 : 的值（不会命中 PasswordAuthentication=yes）
# 2. argon2 哈希
# 3. 40 位以上的随机串；不以 / 开头，因此绝对路径与 URL 路径不受影响
redact() {
  sed -E \
    -e 's/([A-Za-z0-9_]*(TOKEN|PASSWORD|PASSWD|SECRET|KEY)["]?[[:space:]]*[=:][[:space:]]*["]?)[^"[:space:],}]+/\1***REDACTED***/Ig' \
    -e 's/\$argon2[a-z]*\$[^[:space:]"]+/***ARGON2***/g' \
    -e 's#(^|[^A-Za-z0-9+/_-])[A-Za-z0-9+_-][A-Za-z0-9+/_-]{39,}#\1***LONG***#g' <<<"$*"
}

# curl_url URL [curl 参数...]：URL 经标准输入以 curl 配置传入，
# 不出现在进程命令行（避免 token 被 ps 看到）
curl_url() {
  local url=$1
  shift
  url=${url//\\/\\\\}
  url=${url//\"/\\\"}
  printf 'url = "%s"\n' "$url" | curl -fsS -m 10 -K - "$@"
}

conf_get() { # conf_get KEY [file]
  local f="${2:-$VH_CONF}"
  [[ -r "$f" ]] || return 1
  sed -nE "s/^[[:space:]]*$1=[\"']?([^\"']*)[\"']?[[:space:]]*$/\1/p" "$f" | tail -n1
}

# 敏感路径：数据目录本身及其中含秘密/数据的文件与子目录（仅输出存在的）。
# 审计 D-02、plan --diff、apply 快照共用此列表。
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
  local from_vbm
  from_vbm=$(conf_get VW_DATA_DIR "$VBM_CONF" 2>/dev/null || true)
  local ids=()
  mapfile -t ids < <(docker ps -a --format '{{.ID}}' 2>/dev/null)
  local cands=() id src name
  for id in "${ids[@]}"; do
    src=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$id" 2>/dev/null)
    [[ -n "$src" ]] || continue
    docker inspect -f '{{.Config.Image}}' "$id" | grep -qi vaultwarden || continue
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
    log_err "vbm 记录的数据目录 $from_vbm 未找到对应容器，停止（不猜测）"
    return 2
  fi
  case ${#cands[@]} in
    0) log_err "未发现挂载 /data 的 Vaultwarden 容器"; return 2 ;;
    1) VW_CONTAINER=${cands[0]%%|*}; VW_DATA_DIR=${cands[0]#*|}; return 0 ;;
    *) log_err "发现多个候选实例，请在配置中指定 VW_DATA_DIR："; printf '  %s\n' "${cands[@]}" >&2; return 2 ;;
  esac
}

load_instance() {
  VW_DATA_DIR=$(conf_get VW_DATA_DIR || true)
  VW_CONTAINER=$(conf_get VW_CONTAINER || true)
  VW_DOMAIN=$(conf_get VW_DOMAIN || true)
  if [[ -z "$VW_DATA_DIR" ]]; then detect_instance || return $?; fi
  if [[ -n "$VW_DATA_DIR" && ! -d "$VW_DATA_DIR" ]]; then
    log_err "已确认的数据目录 $VW_DATA_DIR 不存在，停止"
    return 2
  fi
}
