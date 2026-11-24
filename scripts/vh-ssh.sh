#!/usr/bin/env bash
# SSH 登录安全：状态、登录密钥、端口、2FA（密钥 + 动态口令，仅 root）、登录记录
# 所有修改：先记录原文件 → 修改 → sshd -t 与生效值校验 → 重载 → 5 分钟防锁死保护
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

PAM_GA_LINE='auth required pam_google_authenticator.so'
PAM_MARK='#vhm# '
GA_ISSUER=VPS-SSH

# 终端二维码：优先用 qrencode 命令；没有时通过 ctypes 直接调用 libqrencode
# （安装 libpam-google-authenticator 时会一并安装 libqrencode4）。内容经环境变量传入，不出现在命令行
QR_PY=$(
  cat <<'PY'
import ctypes, ctypes.util, os, sys
text = os.environ["VH_QR_TEXT"].encode()
lib = None
for cand in [ctypes.util.find_library("qrencode"), "libqrencode.so.4", "libqrencode.so.3", "libqrencode.so"]:
    if not cand:
        continue
    try:
        lib = ctypes.CDLL(cand)
        break
    except OSError:
        pass
if lib is None:
    sys.exit(1)
class QRcode(ctypes.Structure):
    _fields_ = [("version", ctypes.c_int), ("width", ctypes.c_int), ("data", ctypes.POINTER(ctypes.c_ubyte))]
lib.QRcode_encodeString.restype = ctypes.POINTER(QRcode)
lib.QRcode_encodeString.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int]
lib.QRcode_free.argtypes = [ctypes.POINTER(QRcode)]
qr = lib.QRcode_encodeString(text, 0, 1, 2, 1)  # 版本自动、纠错 M、8 位模式、区分大小写
if not qr:
    sys.exit(1)
w, d = qr.contents.width, qr.contents.data
def dark(x, y):
    return 0 <= x < w and 0 <= y < w and d[y * w + x] & 1
rows = []
for y in range(-2, w + 2, 2):  # 每行字符表示上下两个模块，四周留 2 格空白
    rows.append("".join(" " if dark(x, y) and dark(x, y + 1) else "\u2584" if dark(x, y) else "\u2580" if dark(x, y + 1) else "\u2588"
                        for x in range(-2, w + 2)))
lib.QRcode_free(qr)
sys.stdout.buffer.write(("\n".join(rows) + "\n").encode("utf-8"))
PY
)

ga_label() { echo "root@$(hostname)"; }

ga_uri() { # ga_uri 密钥文件：输出 otpauth:// 链接
  python3 - "$1" "$GA_ISSUER" "$(ga_label)" <<'PY'
import sys, urllib.parse
with open(sys.argv[1], encoding="ascii") as fh:
    seed = fh.readline().strip()
issuer, label = sys.argv[2], sys.argv[3]
q = urllib.parse.quote
print(f"otpauth://totp/{q(issuer)}:{q(label)}?secret={seed}&issuer={q(issuer)}&algorithm=SHA1&digits=6&period=30")
PY
}

# ga_show_qr 密钥文件：在终端显示绑定二维码、手动输入用的密钥和 otpauth 链接
ga_show_qr() {
  local uri seed
  uri=$(ga_uri "$1") || { log_err "无法读取动态口令密钥文件 $1"; return 1; }
  seed=$(head -n1 "$1")
  echo "请用手机验证器（Google Authenticator、Microsoft Authenticator、2FAS、Bitwarden 等）扫描下面的二维码："
  echo
  if command -v qrencode >/dev/null 2>&1; then
    printf '%s' "$uri" | qrencode -t ANSIUTF8 -m 2
  elif ! VH_QR_TEXT="$uri" python3 -c "$QR_PY"; then
    log_warn "无法在终端显示二维码（找不到 libqrencode），请用下面的密钥手动添加"
  fi
  echo
  echo "扫不出来时（窗口太小、浅色背景终端），把窗口拉大后重试，或在验证器中选择「输入设置密钥」手动添加："
  echo "    账号：$(ga_label)    类型：基于时间（TOTP，6 位，30 秒）"
  echo "    密钥：$(sed 's/.\{4\}/& /g' <<<"$seed")"
  echo "    链接：$uri"
}

# ---------- 通用 ----------
server_ip() {
  local a
  read -r -a a <<<"${SSH_CONNECTION:-}"
  if [[ -n ${a[2]:-} ]]; then echo "${a[2]}"; else hostname -I 2>/dev/null | awk '{ print $1 }'; fi
}

cur_ports() { sshd_get port | sort -un; }

test_cmd() { echo "ssh -p ${1:-$(cur_ports | head -n1)} root@$(server_ip)"; }

# drop-in 文件 00-vhm.conf：sshd 对同一配置项取第一个值，00 前缀保证优先于其他 drop-in
dropin_del() {
  [[ -f $SSHD_DROPIN ]] || return 0
  local k tmp
  tmp=$(mktemp) || return 1
  cp -- "$SSHD_DROPIN" "$tmp"
  for k in "$@"; do
    grep -viE "^[[:space:]]*${k}[[:space:]]" "$tmp" >"$tmp.n" || true
    mv -f -- "$tmp.n" "$tmp"
  done
  install -m 600 -- "$tmp" "$SSHD_DROPIN"
  rm -f -- "$tmp"
}
dropin_add() {
  install -d -m 755 "$(dirname "$SSHD_DROPIN")"
  [[ -f $SSHD_DROPIN ]] || printf '# 由 vhm 管理，请勿手动修改；可在 vhm [24] 中回滚\n' >"$SSHD_DROPIN"
  printf '%s %s\n' "$1" "$2" >>"$SSHD_DROPIN"
  chmod 600 "$SSHD_DROPIN"
}
dropin_set() { dropin_del "$1" && dropin_add "$1" "$2"; }

# 确保主配置在开头包含 drop-in 目录（Debian 11+/Ubuntu 20.04+ 默认已有）
ensure_include() {
  local d
  d=$(dirname "$SSHD_DROPIN")
  grep -Eq "^[[:space:]]*Include[[:space:]]+$d/\*\.conf" "$SSHD_CONFIG" && return 0
  change_track "$SSHD_CONFIG" || return 1
  sed -i "1i Include $d/*.conf" "$SSHD_CONFIG"
}

expect_eff() { # expect_eff 配置项（小写） 期望值
  local v eff
  eff=$(sshd_eff) || eff=""
  [[ -n $eff ]] || { log_err "无法读取 sshd 生效配置（$SSHD_BIN -T 失败）：$(sshd_eff_err)"; return 1; }
  v=$(awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }' <<<"$eff")
  [[ $v == "$2" ]] && return 0
  log_err "生效值不符：$1 = ${v:-空}（期望 $2）。可能被 $SSHD_CONFIG 或其他 drop-in 覆盖"
  return 1
}

# 应用当前变更：配置检查 → 重载 → 防锁死确认。失败或未确认均自动回滚
commit_ssh_change() { # commit_ssh_change 测试命令
  local out
  if ! out=$(sshd_test); then
    log_err "sshd 配置检查未通过，已放弃修改：$out"
    change_rollback "$CHG_ID"
    return 1
  fi
  if ! ssh_reload; then
    log_err "重载 SSH 服务失败，正在回滚"
    change_rollback "$CHG_ID"
    return 1
  fi
  if ! guard_start; then
    log_err "无法设置自动回滚保护，为安全起见放弃修改"
    change_rollback "$CHG_ID"
    return 1
  fi
  guard_wait_confirm "$1" || return 1
  return 0
}

# ---------- 登录密钥 ----------
KEY_LINE=() KEY_FP=() KEY_DESC=()
load_keys() {
  KEY_LINE=() KEY_FP=() KEY_DESC=()
  [[ -f $ROOT_KEYS ]] || return 0
  local n=0 line out tmp
  tmp=$(mktemp) || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    printf '%s\n' "$line" >"$tmp"
    out=$(ssh-keygen -l -f "$tmp" 2>/dev/null) || continue
    KEY_LINE+=("$n")
    KEY_FP+=("$(awk '{ print $2 }' <<<"$out")")
    KEY_DESC+=("$(awk '{ t = $NF; $1 = $2 = $NF = ""; gsub(/^ +| +$/, ""); print t, ($0 == "" ? "（无备注）" : $0) }' <<<"$out")")
  done <"$ROOT_KEYS"
  rm -f -- "$tmp"
}

# 当前会话使用的密钥指纹（从 sshd 日志匹配本次连接的来源 IP 与端口）
session_fp() {
  local a
  read -r -a a <<<"${SSH_CONNECTION:-}"
  [[ -n ${a[1]:-} ]] || return 0
  auth_log 2 | grep -F "Accepted publickey for root from ${a[0]} port ${a[1]} " | tail -n1 | grep -Eo 'SHA256:[A-Za-z0-9+/=]+' || true
}

list_keys() {
  load_keys
  if ((${#KEY_FP[@]} == 0)); then
    log_warn "root 没有可用的登录密钥（$ROOT_KEYS）"
    return 0
  fi
  local i cur mark
  cur=$(session_fp)
  for i in "${!KEY_FP[@]}"; do
    mark=""
    [[ -n $cur && ${KEY_FP[$i]} == "$cur" ]] && mark="  ← 当前会话"
    printf '  [%d] %s  %s%s\n' "$((i + 1))" "${KEY_FP[$i]}" "${KEY_DESC[$i]}" "$mark"
  done
}

add_key() {
  local line tmp fp
  echo "请粘贴一行公钥（以 ssh-ed25519 / ssh-rsa / ecdsa-sha2-* 开头），回车结束："
  read -r line || return 0
  [[ -n $line ]] || return 0
  tmp=$(mktemp)
  printf '%s\n' "$line" >"$tmp"
  if ! fp=$(ssh-keygen -l -f "$tmp" 2>/dev/null | awk '{ print $2 }'); then
    rm -f -- "$tmp"
    log_err "不是有效的公钥，未添加"
    return 1
  fi
  rm -f -- "$tmp"
  load_keys
  local k
  for k in "${KEY_FP[@]}"; do
    [[ $k == "$fp" ]] && { log_info "该密钥已存在（$fp）"; return 0; }
  done
  confirm_yes "添加密钥 $fp 到 root 的授权列表？" || return 0
  change_begin "添加 root 登录密钥 $fp"
  install -d -m 700 "$(dirname "$ROOT_KEYS")"
  change_track "$ROOT_KEYS" || return 1
  if [[ -s $ROOT_KEYS && -n $(tail -c1 "$ROOT_KEYS") ]]; then echo >>"$ROOT_KEYS"; fi
  printf '%s\n' "$line" >>"$ROOT_KEYS"
  chmod 600 "$ROOT_KEYS"
  change_status applied
  log_ok "已添加。建议另开窗口用新密钥登录试一下"
}

del_key() {
  load_keys
  local n i cur
  ((${#KEY_FP[@]} > 0)) || { log_warn "没有可删除的密钥"; return 0; }
  read -r -p "输入要删除的序号（回车取消）: " n || return 0
  [[ -n $n ]] || return 0
  [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#KEY_FP[@]})) || { log_err "无效序号"; return 1; }
  i=$((n - 1))
  if ((${#KEY_FP[@]} == 1)); then
    log_err "这是唯一的登录密钥，删除后将无法登录，已拒绝"
    return 1
  fi
  cur=$(session_fp)
  if [[ -n $cur && ${KEY_FP[$i]} == "$cur" ]]; then
    log_err "这是当前会话正在使用的密钥。请先用其他密钥登录，再删除它"
    return 1
  fi
  confirm_yes "删除密钥 ${KEY_FP[$i]}  ${KEY_DESC[$i]}？" || return 0
  change_begin "删除 root 登录密钥 ${KEY_FP[$i]}"
  change_track "$ROOT_KEYS" || return 1
  sed -i "${KEY_LINE[$i]}d" "$ROOT_KEYS"
  change_status applied
  log_ok "已删除（可在 [24] 回滚）"
}

keys_menu() {
  while true; do
    title "root 登录密钥（$ROOT_KEYS）"
    list_keys
    echo
    echo "  [1] 添加密钥   [2] 删除密钥   [0] 返回"
    local c
    read -r -p "请选择：" c || return 0
    case $c in
      1) add_key ;;
      2) del_key ;;
      *) return 0 ;;
    esac
  done
}

# ---------- 状态 ----------
show_status() {
  title "SSH 状态"
  local eff
  eff=$(sshd_view)
  if [[ -z $eff ]]; then
    log_err "无法读取 sshd 生效配置（$SSHD_BIN -T 失败）：$(sshd_eff_err)"
    return 1
  fi
  if [[ -z $(sshd_eff) ]]; then
    log_warn "$SSHD_BIN -T 失败（$(sshd_eff_err)），以下根据配置文件推算，可能与实际生效值有出入"
  fi
  get() { awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }' <<<"$eff" | paste -sd' '; }
  printf '  %-22s %s\n' "监听端口" "$(get port)"
  printf '  %-22s %s\n' "密码登录" "$(get passwordauthentication)"
  printf '  %-22s %s\n' "密钥登录" "$(get pubkeyauthentication)"
  printf '  %-22s %s\n' "root 登录" "$(get permitrootlogin)"
  printf '  %-22s %s\n' "键盘交互认证" "$(get kbdinteractiveauthentication)"
  printf '  %-22s %s\n' "认证组合" "$(get authenticationmethods)"
  if tfa_enabled; then
    printf '  %-22s %s\n' "2FA" "已启用（密钥 + 动态口令）"
  elif tfa_pam_on; then
    printf '  %-22s %s\n' "2FA" "PAM 已配置但 sshd 未要求，未生效"
  else
    printf '  %-22s %s\n' "2FA" "未启用"
  fi
  printf '  %-22s %s\n' "root 2FA 绑定" "$([[ -f $GA_FILE ]] && echo "已绑定（应急码剩余 $(grep -cE '^[0-9]{8}$' "$GA_FILE")）" || echo 未绑定)"
  load_keys
  printf '  %-22s %s\n' "root 授权密钥" "${#KEY_FP[@]} 个"
  printf '  %-22s %s\n' "时间同步" "$(time_synced && echo 已同步 || echo 未同步（动态口令会失败）)"
  [[ -f $SSHD_DROPIN ]] && printf '  %-22s %s\n' "vhm 配置文件" "$SSHD_DROPIN"
  echo
  echo "当前登录会话："
  who 2>/dev/null | sed 's/^/  /'
  if [[ -d /opt/1panel ]]; then
    echo
    log_info "SSH 由 vhm 管理时，1Panel「SSH 管理」页面显示的值可能与实际生效值不一致，以这里为准"
  fi
}

time_synced() { [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; }

# ---------- 登录记录 ----------
auth_log() { # auth_log 天数：输出 sshd 日志行
  local days=${1:-7}
  if command -v journalctl >/dev/null 2>&1 && journalctl -q --no-pager -n1 -t sshd -t sshd-session >/dev/null 2>&1; then
    journalctl -q --no-pager -o short-iso -t sshd -t sshd-session --since "-${days}d" 2>/dev/null
  else
    cat /var/log/auth.log /var/log/secure 2>/dev/null | grep -E 'sshd(-session)?\['
  fi
}

show_logins() {
  local days log
  days=$(read_default "统计最近多少天" 7)
  [[ $days =~ ^[0-9]+$ ]] || days=7
  log=$(auth_log "$days")
  title "最近 $days 天成功登录（最多 15 条）"
  grep -E 'Accepted (publickey|password|keyboard-interactive/pam)' <<<"$log" |
    sed -nE 's/^([^ ]+).*Accepted ([^ ]+) for ([^ ]+) from ([^ ]+) port.*/  \1  \3  \4  \2/p' | tail -n 15
  title "失败来源 IP 排行（最多 15 个）"
  grep -E 'Failed (password|publickey|keyboard-interactive)|Invalid user|authentication failure|Connection closed by (authenticating|invalid) user|maximum authentication attempts' <<<"$log" |
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-f]*:[0-9a-f:]+:[0-9a-f]+' | sort | uniq -c | sort -rn | head -n 15 |
    awk '{ printf "  %6d 次  %s\n", $1, $2 }'
  echo
  echo "提示：经常成功登录的固定 IP 可以加入 Fail2Ban 白名单（[15]）。"
}

# ---------- 端口 ----------
# 防火墙放行检查（port_allowed / wait_port_allowed）在 vh-common.sh 中，与 1Panel 面板端口共用
socket_sync_ports() { # Ubuntu 22.10+ 的 ssh.socket：没有 sshd-socket-generator 时由 vhm 写 ListenStream
  ssh_socket_used || return 0
  local g
  for g in /usr/lib/systemd/system-generators/sshd-socket-generator /lib/systemd/system-generators/sshd-socket-generator; do
    [[ -x $g ]] && return 0
  done
  change_track "$SSH_SOCKET_DROPIN" || return 1
  install -d -m 755 "$(dirname "$SSH_SOCKET_DROPIN")"
  {
    echo "# 由 vhm 管理"
    echo "[Socket]"
    echo "ListenStream="
    for g in "$@"; do echo "ListenStream=$g"; done
  } >"$SSH_SOCKET_DROPIN"
}

set_ports() { # set_ports 端口...：drop-in 中只保留这些端口，并注释主配置中的 Port
  local p
  dropin_del Port
  for p in "$@"; do dropin_add Port "$p"; done
  sed -i -E "s/^([[:space:]]*Port[[:space:]].*)$/${PAM_MARK}\1/I" "$SSHD_CONFIG"
  socket_sync_ports "$@"
}

change_port() {
  local cur new p others
  mapfile -t cur < <(cur_ports)
  title "修改 SSH 端口"
  echo "当前端口：${cur[*]:-未知}"
  read -r -p "新端口（1024-65535，回车取消）: " new || return 0
  [[ -n $new ]] || return 0
  [[ $new =~ ^[0-9]+$ ]] && ((new >= 1024 && new <= 65535)) || { log_err "端口需在 1024-65535 之间"; return 1; }
  for p in "${cur[@]}"; do [[ $p == "$new" ]] && { log_info "端口未变化"; return 0; }; done
  if [[ -n $(ss -ltnH "sport = :$new" 2>/dev/null) ]]; then
    log_err "端口 $new 已被其他程序占用"
    return 1
  fi
  others=$(grep -lisE '^[[:space:]]*Port[[:space:]]' "$(dirname "$SSHD_DROPIN")"/*.conf 2>/dev/null | grep -vF "$SSHD_DROPIN" || true)
  [[ -n $others ]] && log_warn "以下文件也设置了 Port，sshd 会同时监听：$others"
  wait_port_allowed "$new" || { log_info "已取消"; return 0; }
  echo
  echo "步骤：先同时监听 ${cur[*]} 和 $new → 你用新端口登录确认 → 关闭旧端口。"
  [[ -f $F2B_JAIL ]] && echo "Fail2Ban 的 SSH 防护会同步改为端口 $new。"
  confirm_yes "确认把 SSH 端口改为 $new？" || return 0

  change_begin "SSH 端口 ${cur[*]} → $new" sshd fail2ban
  ensure_include || { change_rollback "$CHG_ID"; return 1; }
  change_track "$SSHD_CONFIG" && change_track "$SSHD_DROPIN" || { change_rollback "$CHG_ID"; return 1; }
  set_ports "${cur[@]}" "$new" || { change_rollback "$CHG_ID"; return 1; }
  commit_ssh_change "$(test_cmd "$new")" || return 1

  # 第二步：关闭旧端口
  set_ports "$new" || { change_rollback "$CHG_ID"; return 1; }
  if [[ -f $F2B_JAIL ]]; then
    change_track "$F2B_JAIL" && sed -i -E "s/^port[[:space:]]*=.*/port = $new/" "$F2B_JAIL" && f2b_reload ||
      log_warn "Fail2Ban 端口同步失败，请在 [15] 重新保存配置"
  fi
  if ! ssh_reload; then
    log_err "关闭旧端口失败，正在回滚"
    change_rollback "$CHG_ID"
    return 1
  fi
  change_status applied
  log_ok "SSH 端口已改为 $new（旧端口已关闭）。确认无误后可在 1Panel 防火墙中删除旧端口规则"
}

# ---------- 2FA ----------
ga_installed() { [[ -e /lib/x86_64-linux-gnu/security/pam_google_authenticator.so ]] || compgen -G '/lib*/*/security/pam_google_authenticator.so' >/dev/null || compgen -G '/usr/lib*/*/security/pam_google_authenticator.so' >/dev/null || compgen -G '/lib*/security/pam_google_authenticator.so' >/dev/null; }

ga_install() {
  ga_installed && command -v google-authenticator >/dev/null 2>&1 && return 0
  confirm_yes "需要安装 libpam-google-authenticator（动态口令模块），现在安装？" || return 1
  apt_install libpam-google-authenticator || return 1
}

totp_check() { # totp_check 密钥文件；从标准输入读取 6 位动态口令
  python3 -c '
import base64, hashlib, hmac, struct, sys, time
with open(sys.argv[1], encoding="ascii") as fh:
    seed = fh.readline().strip()
code = sys.stdin.readline().strip()
key = base64.b32decode(seed + "=" * (-len(seed) % 8), casefold=True)
t = int(time.time()) // 30
for d in (-1, 0, 1):
    h = hmac.new(key, struct.pack(">Q", t + d), hashlib.sha1).digest()
    o = h[-1] & 15
    if "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000) == code:
        sys.exit(0)
sys.exit(1)
' "$1"
}

# 生成新绑定到临时文件并校验一次动态口令；成功后输出临时文件路径
ga_bind_new() {
  local f="$GA_FILE.vhm-new" code i
  rm -f -- "$f"
  time_synced || log_warn "系统时间未同步，动态口令可能校验失败（timedatectl set-ntp true）"
  local out
  # -C：不在这里要求输入验证码（vhm 随后自己校验）。新版 google-authenticator 默认会提示
  # 「Enter code from app」，而输出被捕获后提示不可见，程序会一直等待输入，看起来像卡住。
  # </dev/null 保证即使将来又多出交互提问，也会立即失败而不是挂起。
  if ! out=$(google-authenticator -t -d -f -C -r 3 -R 30 -w 3 -e 5 -Q NONE -s "$f" \
    -i "$GA_ISSUER" -l "$(ga_label)" </dev/null 2>&1) || [[ ! -s $f ]]; then
    log_err "生成动态口令密钥失败：$(tail -n 3 <<<"$out" | redact)"
    rm -f -- "$f"
    return 1
  fi
  unset out
  ga_show_qr "$f" >&2 || { rm -f -- "$f"; return 1; }
  echo >&2
  for i in 1 2 3; do
    read -r -p "输入验证器上显示的 6 位动态口令: " code || break
    if [[ $code =~ ^[0-9]{6}$ ]] && totp_check "$f" <<<"$code"; then
      log_ok "动态口令正确" >&2
      echo >&2
      printf '%s请把下面 5 个应急码抄下来保存在安全的地方（每个只能用一次，手机丢失时使用）：%s\n' "$C_Y" "$C_0" >&2
      grep -E '^[0-9]{8}$' "$f" | sed 's/^/    /' >&2
      read -r -p "已保存应急码？按 Enter 继续 " _ || true
      chmod 400 "$f"
      echo "$f"
      return 0
    fi
    log_warn "动态口令不正确（还剩 $((3 - i)) 次）" >&2
  done
  rm -f -- "$f"
  log_err "未通过校验，绑定已取消"
  return 1
}

pam_enable_ga() {
  python3 - "$PAM_SSHD" "$PAM_GA_LINE" "$PAM_MARK" <<'PY'
import re, sys
path, ga, mark = sys.argv[1:]
lines = open(path, encoding="utf-8").read().splitlines()
out, done = [], False
for line in lines:
    s = line.strip()
    if re.match(r"auth\s+\S+\s+pam_google_authenticator\.so", s):
        continue
    if not done and re.match(r"@include\s+common-auth\b", s):
        out += [mark + line, ga]
        done = True
        continue
    out.append(line)
if not done:
    sys.exit("[错误] /etc/pam.d/sshd 中没有 @include common-auth，不支持此 PAM 布局，未修改")
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}

pam_disable_ga() {
  python3 - "$PAM_SSHD" "$PAM_MARK" <<'PY'
import re, sys
path, mark = sys.argv[1:]
out = []
for line in open(path, encoding="utf-8").read().splitlines():
    if re.match(r"\s*auth\s+\S+\s+pam_google_authenticator\.so", line):
        continue
    out.append(line[len(mark):] if line.startswith(mark) else line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}

tfa_enable() {
  title "启用 SSH 2FA（密钥 + 动态口令）"
  if tfa_enabled; then
    log_ok "2FA 已启用。重新绑定、查看应急码或关闭请使用 [07]"
    return 0
  fi
  load_keys
  if ((${#KEY_FP[@]} == 0)); then
    log_err "root 没有可用的登录密钥（$ROOT_KEYS）。启用后必须用密钥登录，请先在 [04] 添加密钥"
    return 1
  fi
  echo "启用后 root 的 SSH 登录必须同时满足：① 你的 SSH 密钥 ② 手机上的 6 位动态口令。密码登录会关闭。"
  echo "root 当前有 ${#KEY_FP[@]} 个授权密钥，请确认都是你自己的："
  list_keys
  local others
  others=$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1 }' /etc/passwd | paste -sd' ')
  [[ -n $others ]] && log_warn "其他可登录用户（$others）没有绑定动态口令，启用后将无法通过 SSH 登录"
  [[ -d /opt/1panel ]] && log_warn "1Panel 的「终端」功能通过 SSH 连接本机，启用 2FA 后将无法使用（「容器终端」不受影响）"
  echo "VPS 服务商控制台的 VNC 登录不受影响，可作为最后的应急入口。"
  time_synced || log_warn "系统时间未同步，动态口令可能失败。建议先执行：timedatectl set-ntp true"
  confirm_yes "继续启用？" || return 0
  ga_install || return 1

  local newga=""
  if [[ -f $GA_FILE ]] && ! confirm_yes "root 已有动态口令绑定（$GA_FILE），输入 yes 重新绑定，其他输入沿用现有绑定"; then
    log_info "沿用现有绑定"
  else
    newga=$(ga_bind_new) || return 1
  fi

  change_begin "启用 SSH 2FA（密钥 + 动态口令）" sshd
  {
    ensure_include &&
      change_track "$PAM_SSHD" && change_track "$SSHD_DROPIN" && change_track "$GA_FILE" &&
      { [[ -z $newga ]] || mv -f -- "$newga" "$GA_FILE"; } &&
      pam_enable_ga &&
      dropin_set UsePAM yes &&
      dropin_set PubkeyAuthentication yes &&
      dropin_set PasswordAuthentication no &&
      dropin_set PermitEmptyPasswords no &&
      dropin_set KbdInteractiveAuthentication yes &&
      # OpenSSH 8.7 之前（Debian 11）键盘交互认证由 ChallengeResponseAuthentication 控制，之后为其别名
      dropin_set ChallengeResponseAuthentication yes &&
      dropin_set AuthenticationMethods publickey,keyboard-interactive &&
      # 认证组合已强制先通过密钥；prohibit-password 会同时禁止动态口令，所以这里必须为 yes
      dropin_set PermitRootLogin yes
  } || { log_err "写入配置失败，正在回滚"; change_rollback "$CHG_ID"; return 1; }
  if ! { expect_eff authenticationmethods publickey,keyboard-interactive &&
    expect_eff passwordauthentication no && expect_eff kbdinteractiveauthentication yes && expect_eff usepam yes; }; then
    change_rollback "$CHG_ID"
    return 1
  fi
  commit_ssh_change "$(test_cmd)" || return 1
  change_status applied
  log_ok "SSH 2FA 已启用：密钥 + 动态口令"
}

tfa_rebind() {
  ga_install || return 1
  local newga
  newga=$(ga_bind_new) || return 1
  change_begin "重新绑定 root 动态口令"
  change_track "$GA_FILE" && mv -f -- "$newga" "$GA_FILE" || { change_rollback "$CHG_ID"; return 1; }
  if tfa_enabled; then
    if ! guard_start; then
      change_rollback "$CHG_ID"
      return 1
    fi
    log_info "旧的动态口令和应急码已失效"
    guard_wait_confirm "$(test_cmd)" || return 1
  fi
  change_status applied
  log_ok "已重新绑定"
}

tfa_codes() {
  [[ -f $GA_FILE ]] || { log_warn "root 尚未绑定动态口令"; return 0; }
  local codes
  codes=$(grep -E '^[0-9]{8}$' "$GA_FILE" || true)
  if [[ -z $codes ]]; then
    log_warn "应急码已全部用完，请选择「重新绑定」生成新的"
    return 0
  fi
  echo "剩余应急码（每个只能用一次）："
  sed 's/^/    /' <<<"$codes"
}

tfa_qr() {
  [[ -f $GA_FILE ]] || { log_warn "root 尚未绑定动态口令，请先用 [06] 启用 2FA"; return 0; }
  log_warn "二维码和密钥就等于你的动态口令。请确认周围没人看屏幕，终端也没有在录屏或记录会话日志"
  confirm_yes "显示 root 的动态口令二维码？" || return 0
  echo
  ga_show_qr "$GA_FILE"
  echo
  echo "可以用它在新手机或第二个验证器上添加同一个账号，原来手机上的口令仍然有效。"
  echo "如果担心密钥已经泄露，请改用「重新绑定」，旧的二维码和应急码会全部失效。"
}

tfa_disable() {
  tfa_enabled || tfa_pam_on || { log_info "2FA 未启用"; return 0; }
  echo "关闭后 root 只需 SSH 密钥即可登录，密码登录保持关闭。动态口令绑定文件会保留，以后可直接重新启用。"
  confirm_yes "确认关闭 SSH 2FA？" || return 0
  change_begin "关闭 SSH 2FA" sshd
  {
    change_track "$PAM_SSHD" && change_track "$SSHD_DROPIN" &&
      pam_disable_ga &&
      dropin_del AuthenticationMethods KbdInteractiveAuthentication ChallengeResponseAuthentication &&
      dropin_set PasswordAuthentication no &&
      dropin_set PermitRootLogin prohibit-password
  } || { change_rollback "$CHG_ID"; return 1; }
  commit_ssh_change "$(test_cmd)" || return 1
  change_status applied
  log_ok "SSH 2FA 已关闭"
}

tfa_manage() {
  title "2FA 管理"
  if tfa_enabled; then log_ok "2FA 已启用"; else log_info "2FA 未启用（启用请用 [06]）"; fi
  echo
  echo "  [1] 显示绑定二维码（在新手机 / 第二个验证器上添加同一账号）"
  echo "  [2] 重新绑定（换新密钥：密钥泄露 / 应急码用完）"
  echo "  [3] 查看剩余应急码"
  echo "  [4] 关闭 2FA"
  echo "  [0] 返回"
  local c
  read -r -p "请选择：" c || return 0
  case $c in
    1) tfa_qr ;;
    2) tfa_rebind ;;
    3) tfa_codes ;;
    4) tfa_disable ;;
  esac
}

case ${1:-status} in
  status) show_status ;;
  keys) need_root; with_lock keys_menu ;;
  port) need_root; with_lock change_port ;;
  2fa-enable) need_root; with_lock tfa_enable ;;
  2fa-manage) need_root; with_lock tfa_manage ;;
  logins) show_logins ;;
  *) die "未知参数：$1" ;;
esac
