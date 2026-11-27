# shellcheck shell=bash
# shellcheck disable=SC2034
# 日志、软件包安装、交互、锁、脱敏、键值文件；由 vh-common.sh 加载，不要单独执行

# ---------- 日志 ----------
_log_file() {
  [[ -w "$(dirname "$VH_LOG")" ]] || return 0
  [[ ! -L "$VH_LOG" ]] || return 0
  if [[ ! -e "$VH_LOG" ]]; then
    (umask 077; : >>"$VH_LOG") 2>/dev/null || true
  fi
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
  if [[ -n $proxy ]]; then
    # 代理地址可能内嵌 user:password@，写日志前先去掉凭据部分
    proxy=$(printf '%s' "$proxy" | sed -E 's#(://)[^/@[:space:]]+@#\1***@#g')
    log_warn "apt 配置了代理（$proxy），请确认代理可用"
  fi
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
  if [[ -L "$VH_LOCK" ]]; then
    log_err "锁文件是符号链接，拒绝使用：$VH_LOCK"
    exit 1
  fi
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

# 最多等待 N 秒再拿全局锁；用于自动回滚，避免和用户正在进行的修改并发写配置
with_lock_wait() {
  local wait=$1
  shift
  if [[ "${VH_LOCK_HELD:-0}" == 1 ]]; then
    "$@"
    return
  fi
  mkdir -p "$(dirname "$VH_LOCK")" 2>/dev/null || true
  if [[ -L "$VH_LOCK" ]]; then
    log_err "锁文件是符号链接，拒绝使用：$VH_LOCK"
    exit 1
  fi
  if ! exec 9>"$VH_LOCK"; then
    log_err "无法打开锁文件 $VH_LOCK"
    exit 1
  fi
  if ! flock -w "$wait" 9; then
    log_warn "等待其他 vhm 修改操作超过 ${wait} 秒，本次自动回滚暂缓（退出码 $VH_EXIT_LOCKED）"
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

# systemd 单元等由 vhm 生成的文件：内容相同则不动。返回 0 = 已改写，1 = 无需改写，2 = 写入失败
unit_write() { # unit_write 文件 内容
  [[ $(cat "$1" 2>/dev/null) == "$2" ]] && return 1
  printf '%s\n' "$2" >"$1" || return 2
}
