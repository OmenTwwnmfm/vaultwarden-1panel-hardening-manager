#!/usr/bin/env bash
# VPS 安全体检（只读）：端口与放行规则、Docker 暴露、SSH、Fail2Ban、系统、1Panel、Vaultwarden
# 结果分为 正常 / 注意 / 危险，每项附一句处理建议；不修改任何配置
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

N_OK=0 N_WARN=0 N_BAD=0
chk() { # chk ok|warn|bad 标题 说明 [建议]
  local tag
  case $1 in
    ok) tag="${C_G}[正常]${C_0}"; N_OK=$((N_OK + 1)) ;;
    warn) tag="${C_Y}[注意]${C_0}"; N_WARN=$((N_WARN + 1)) ;;
    *) tag="${C_R}[危险]${C_0}"; N_BAD=$((N_BAD + 1)) ;;
  esac
  printf '  %s %s：%s\n' "$tag" "$2" "$(redact "$3")"
  [[ $1 != ok && -n ${4:-} ]] && printf '         %s→ %s%s\n' "$C_D" "$4" "$C_0"
  return 0
}

public_addr() { [[ $1 == 0.0.0.0 || $1 == '*' || $1 == '[::]' || $1 == :: || $1 == '' ]]; }

# ---------- 端口暴露 ----------
# 防火墙规则由 1Panel 管理，这里只看「监听在所有地址上的端口」在防火墙中是否对所有 IP 放行
check_ports() {
  title "端口暴露"
  local fw proto addr host port proc open=() limited=() blocked=()
  local -A seen=()
  fw=$(fw_type)
  if [[ $fw == none ]]; then
    chk bad "主机防火墙" "未启用，所有监听在所有地址上的端口都对公网开放" "在 1Panel →「主机」→「防火墙」启用，并只放行需要的端口"
  else
    chk ok "主机防火墙" "$(fw_label "$fw") 已启用"
  fi
  command -v ss >/dev/null 2>&1 || return 0
  while read -r proto addr proc; do
    host=${addr%:*} port=${addr##*:}
    public_addr "$host" || continue
    proto=${proto/tcp*/tcp} proto=${proto/udp*/udp}
    [[ -z ${seen[$proto/$port]+x} ]] || continue
    seen[$proto/$port]=1
    proc=$(sed -nE 's/.*\(\("([^"]+)".*/\1/p' <<<"$proc")
    case $(port_scope "$port" "$proto") in
      all) open+=("$port/$proto(${proc:-?})") ;;
      limited) limited+=("$port/$proto(${proc:-?})") ;;
      none) blocked+=("$port/$proto") ;;
      *) open+=("$port/$proto(${proc:-?})?") ;;
    esac
  done < <(ss -H -tulpn 2>/dev/null | awk '{ print $1, $5, $7 }')
  if ((${#open[@]})); then
    chk warn "对所有 IP 开放的端口" "${open[*]}" "逐个确认是否需要对外；面板、数据库等管理端口建议在 1Panel 防火墙中只放行你的 IP（? 表示无法判断放行范围）"
  else
    chk ok "对所有 IP 开放的端口" "无"
  fi
  ((${#limited[@]})) && chk ok "只对指定 IP 放行" "${limited[*]}"
  ((${#blocked[@]})) && chk ok "监听但被防火墙拦截" "${blocked[*]}"
  return 0
}

# ---------- Docker 暴露 ----------
# Docker 发布的端口走 FORWARD 链，不经过 INPUT，所以 ufw / firewalld / 1Panel 的普通放行规则拦不住。
# 1Panel v2 的 Docker 端口访问控制（nft_1panel_docker / 1PANEL_DOCKER）可以拦截，检测到时降为提示。
check_docker() {
  title "Docker 端口暴露"
  command -v docker >/dev/null 2>&1 || { chk ok "Docker" "未安装"; return 0; }
  local name binds b ip found=0 seen guard=0 level=bad
  ip=$(hostname -I 2>/dev/null | awk '{ print $1 }')
  if docker_guard_on; then
    guard=1 level=warn
    echo "  已检测到 1Panel 的 Docker 端口访问控制，以下端口是否可达以 1Panel 中的规则为准。"
  fi
  while IFS='|' read -r name binds; do
    seen=" "
    for b in $binds; do
      [[ $b == *'->'* ]] || continue
      local hp=${b%%->*} host port
      host=${hp%:*} port=${hp##*:}
      public_addr "$host" || continue
      # 同一端口的 IPv4 与 IPv6 绑定只报告一次
      [[ $seen == *" $port "* ]] && continue
      seen+="$port "
      found=1
      local proof=""
      if [[ -n $ip ]] && curl -s -o /dev/null -m 3 "http://$ip:$port/" 2>/dev/null; then proof="，本机通过 $ip:$port 实测可访问"; fi
      if ((guard)); then
        chk "$level" "容器 $name" "端口 $port 发布在所有地址上$proof" \
          "不需要直接对外的，在 1Panel →「已安装应用」→ 参数中取消「端口外部访问」，由 OpenResty 反代"
      else
        chk "$level" "容器 $name" "端口 $port 发布在所有地址上$proof；Docker 会绕过主机防火墙，1Panel 防火墙里关掉也拦不住" \
          "在 1Panel →「已安装应用」→ 参数中取消「端口外部访问」，改为只监听 127.0.0.1，由 OpenResty 反代"
      fi
    done
  done < <(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | sed 's/, / /g')
  ((found)) || chk ok "容器端口" "没有容器把端口发布在所有地址上"
  return 0
}

# ---------- SSH ----------
check_ssh() {
  title "SSH"
  local eff pa pk prl port mat lgt x11 pep
  eff=$(sshd_view)
  if [[ -z $eff ]]; then
    chk warn "SSH 配置" "无法读取 sshd -T" "检查 sshd 配置：sshd -t"
    return 0
  fi
  [[ -n $(sshd_eff) ]] || chk warn "SSH 配置" "sshd -T 失败，以下根据配置文件推算" "运行 [26] 诊断查看原因"
  pa=$(awk '$1 == "passwordauthentication" { print $2 }' <<<"$eff")
  pk=$(awk '$1 == "pubkeyauthentication" { print $2 }' <<<"$eff")
  prl=$(awk '$1 == "permitrootlogin" { print $2 }' <<<"$eff")
  port=$(awk '$1 == "port" { print $2 }' <<<"$eff" | paste -sd' ')
  if [[ $port == 22 ]]; then chk warn "SSH 端口" "22（默认端口，扫描最多）" "可在 [05] 修改"; else chk ok "SSH 端口" "$port"; fi
  if [[ $pa == yes ]]; then chk bad "密码登录" "已开启" "可在 [06] 选择密钥登录或增加动态口令"; else chk ok "密码登录" "已关闭"; fi
  if [[ $pk == yes ]]; then chk ok "密钥登录" "已开启"; else chk warn "密钥登录" "已关闭" "可在 [06] 选择密钥登录"; fi
  if tfa_enabled; then
    chk ok "SSH 2FA" "已启用，root 登录：$prl"
  elif tfa_pam_nullok; then
    chk bad "SSH 2FA" "PAM 带 nullok，未绑定动态口令也能登录" "在 [06] 重新选择登录方式"
  elif tfa_pam_on; then
    chk bad "SSH 2FA" "PAM 已配置但 sshd 未要求 keyboard-interactive" "检查 AuthenticationMethods"
  else
    chk warn "SSH 2FA" "未启用，root 登录：$prl" "在 [06] 选择登录方式"
  fi
  if [[ $prl == no ]]; then
    chk ok "root 直接登录" "已禁止"
  elif tfa_enabled; then
    chk ok "root 直接登录" "允许（$prl），但必须通过动态口令"
  elif [[ $prl == yes && $pa == yes ]]; then
    chk bad "root 直接登录" "允许 root 用密码登录" "在 [06] 改为密钥登录，或增加动态口令"
  else
    chk warn "root 直接登录" "允许（$prl）" "可在 [06] 启用密钥 + 动态口令；长期建议改用普通 sudo 用户登录并设置 PermitRootLogin no，见使用手册「改用普通用户登录」"
  fi
  # 以下几项只在 sshd -T 可用时才有值；读不到就不显示
  mat=$(awk '$1 == "maxauthtries" { print $2 }' <<<"$eff")
  lgt=$(awk '$1 == "logingracetime" { print $2 }' <<<"$eff")
  x11=$(awk '$1 == "x11forwarding" { print $2 }' <<<"$eff")
  pep=$(awk '$1 == "permitemptypasswords" { print $2 }' <<<"$eff")
  if [[ $pep == yes ]]; then chk bad "空密码登录" "PermitEmptyPasswords yes" "立即改为 PermitEmptyPasswords no"; fi
  if [[ $mat =~ ^[0-9]+$ ]] && ((mat > 6)); then
    chk warn "MaxAuthTries" "$mat 次" "建议不超过 6，例如在 /etc/ssh/sshd_config 中设置 MaxAuthTries 3"
  fi
  if [[ $lgt =~ ^[0-9]+$ ]] && ((lgt == 0 || lgt > 120)); then
    chk warn "LoginGraceTime" "${lgt} 秒（0 表示不限制）" "建议 30–60 秒，未完成登录的连接会更快被断开"
  fi
  if [[ $x11 == yes ]]; then chk warn "X11Forwarding" "已开启" "VPS 通常不需要图形转发，建议设置 X11Forwarding no"; fi
  if [[ -f $ROOT_KEYS ]] && [[ $(stat -c %a "$ROOT_KEYS") =~ [0-7][1-7][0-7]$|[0-7][0-7][1-7]$ ]]; then
    chk warn "authorized_keys 权限" "$(stat -c %a "$ROOT_KEYS")" "chmod 600 $ROOT_KEYS"
  fi
  if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; then
    chk ok "时间同步" "已同步"
  else
    chk warn "时间同步" "未同步，动态口令可能校验失败" "timedatectl set-ntp true"
  fi
}

# ---------- Fail2Ban ----------
check_f2b() {
  title "Fail2Ban"
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    chk warn "Fail2Ban" "未安装" "在 [16] 安装并配置 SSH 防护"
  elif ! systemctl is-active --quiet fail2ban; then
    chk bad "Fail2Ban" "已安装但未运行" "systemctl enable --now fail2ban，或在 [16] 重新配置"
  elif ! fail2ban-client status sshd >/dev/null 2>&1; then
    chk warn "Fail2Ban" "运行中，但没有 sshd 防护" "在 [16] 配置"
  else
    chk ok "Fail2Ban" "sshd 防护运行中，当前封禁 $(f2b_banned) 个 IP"
  fi
}

# ---------- 系统 ----------
check_system() {
  title "系统"
  local u0 sudoers
  u0=$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/passwd | paste -sd' ')
  if [[ -n $u0 ]]; then chk bad "UID 为 0 的账户" "root 以外：$u0" "确认来源，不认识的立即删除"; else chk ok "UID 为 0 的账户" "只有 root"; fi
  sudoers=$(getent group sudo wheel 2>/dev/null | awk -F: '{ print $4 }' | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd' ')
  if [[ -n $sudoers ]]; then chk warn "sudo 用户" "$sudoers" "确认都是你认识的账户"; else chk ok "sudo 用户" "无（仅 root）"; fi
  if [[ $(apt-config dump 2>/dev/null | sed -nE 's/^APT::Periodic::Unattended-Upgrade "([0-9]+)";/\1/p') =~ ^[1-9] ]] && systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
    chk ok "自动安全更新" "已启用"
  else
    chk warn "自动安全更新" "未启用" "在 [23] 启用"
  fi
  local bad=() k want v
  for k in net.ipv4.tcp_syncookies=1 net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.all.accept_source_route=0; do
    want=${k#*=} k=${k%%=*}
    v=$(sysctl -n "$k" 2>/dev/null) || continue
    [[ $k == *rp_filter && $v == 2 ]] && continue
    [[ $v == "$want" ]] || bad+=("$k=$v")
  done
  if ((${#bad[@]})); then chk warn "内核网络参数" "${bad[*]}" "在 [24] 加固"; else chk ok "内核网络参数" "已加固"; fi
  if [[ -f /var/run/reboot-required ]]; then chk warn "重启" "有更新需要重启才能生效" "择机重启 VPS"; fi
  local unit target missing=()
  for unit in /etc/systemd/system/vhm-*.service; do
    [[ -f $unit ]] || continue
    target=$(sed -nE 's#^ExecStart=/bin/bash ([^ ]+).*#\1#p' "$unit" | head -n1)
    [[ -z $target || -f $target ]] || missing+=("${unit##*/}")
  done
  if ((${#missing[@]})); then
    chk bad "vhm 后台服务" "${missing[*]} 指向的脚本不存在（项目目录被移动或删除？）" "在项目当前位置运行 sudo bash ./run.sh，进入菜单时会自动修正"
  fi
}

# ---------- 1Panel ----------
check_panel() {
  panel_installed || return 0
  title "1Panel 面板"
  local url port entrance
  url=$(panel_url)
  if [[ -z $url ]]; then
    chk warn "1Panel" "无法读取 1pctl user-info" "确认 1pctl 可用"
    return 0
  fi
  port=$(panel_port_of "$url")
  entrance=$(panel_entrance_of "$url")
  if panel_active; then chk ok "面板服务" "运行中（$(panel_version || echo 版本未知)）"; else chk warn "面板服务" "未运行" "在 [13] 启动"; fi
  case $(port_scope "${port:-0}") in
    all) chk warn "面板端口" "$port 对所有 IP 放行" "在 1Panel 防火墙中只放行你的 IP，或在「面板设置」→「安全」设置授权 IP" ;;
    limited) chk ok "面板端口" "$port 只对指定 IP 放行" ;;
    none) chk ok "面板端口" "$port（防火墙中没有单独的放行规则）" ;;
    *) chk ok "面板端口" "${port:-?}" ;;
  esac
  [[ $port == 10086 || $port == 8888 ]] && chk warn "面板端口" "$port 是常见默认端口" "在 [10] 修改"
  if [[ -z $entrance ]]; then chk bad "安全入口" "未设置" "1Panel →「面板设置」→「安全」设置安全入口"; else chk ok "安全入口" "已设置"; fi
  if [[ $url == https://* ]]; then chk ok "面板 HTTPS" "已启用"; else chk warn "面板 HTTPS" "未启用，登录密码以明文传输" "1Panel →「面板设置」→「安全」启用面板 SSL"; fi
  echo "  两步验证（MFA）无法自动读取，请在 1Panel →「面板设置」→「安全」确认已开启。"
}

# ---------- Vaultwarden ----------
check_vw() {
  title "Vaultwarden"
  if ! load_instance >/dev/null 2>&1; then
    chk warn "实例" "未识别" "运行 [01] 首次配置"
    return 0
  fi
  echo "  实例：$VW_CONTAINER（$VW_DATA_DIR）"
  local sig domain
  sig=$(vw_eff signups_allowed SIGNUPS_ALLOWED true)
  if [[ $sig == false ]]; then chk ok "开放注册" "已关闭"; else chk bad "开放注册" "已开启，任何人都能注册" "在 [19] 关闭"; fi
  case $(vw_admin_state) in
    off) chk ok "后台 /admin" "已关闭" ;;
    argon2) chk warn "后台 /admin" "已开启（argon2 哈希令牌）" "不用时在 [20] 关闭，或在 OpenResty 中限制 /admin 的来源 IP" ;;
    plain) chk bad "后台 /admin" "已开启，令牌为明文保存" "在 [20] 更换为 argon2 哈希令牌" ;;
    notoken) chk bad "后台 /admin" "免令牌访问（DISABLE_ADMIN_TOKEN=true）" "在 [20] 关闭或设置令牌" ;;
  esac
  domain=$(vw_eff domain DOMAIN "")
  if [[ $domain == https://* ]]; then chk ok "DOMAIN" "$domain"; else chk bad "DOMAIN" "${domain:-未设置}（非 https）" "1Panel 网站中为该域名启用 HTTPS，并在应用参数中设置 https:// 域名"; fi
  local loose=() p m
  while IFS= read -r p; do
    m=$(stat -c '%a' "$p") || continue
    (((8#$m & 8#077) != 0)) && loose+=("${p#"$VW_DATA_DIR"/}:$m")
  done < <(vw_sensitive_paths)
  if ((${#loose[@]})); then chk warn "数据目录权限" "同组或其他用户可访问：${loose[*]}" "chmod -R go-rwx $VW_DATA_DIR"; else chk ok "数据目录权限" "同组和其他用户无权限"; fi
  if command -v vbm >/dev/null 2>&1 || vbm_installed; then
    local res st when
    res=/var/lib/vaultwarden-backup/last-result.env
    st=$(conf_get STATUS "$res" 2>/dev/null || true)
    when=$(conf_get FINISHED_AT "$res" 2>/dev/null || true)
    case $st in
      success) chk ok "备份（vbm）" "最近一次成功：${when:-?}" ;;
      "") chk warn "备份（vbm）" "已安装，但没有备份记录" "在 vbm 中执行一次备份" ;;
      *) chk bad "备份（vbm）" "最近一次 $st：${when:-?}" "在 vbm 中查看备份日志" ;;
    esac
  else
    chk bad "备份（vbm）" "未安装 vaultwarden-backup-manager" "安装 vbm 并配置自动备份"
  fi
}

summary() {
  echo
  printf '体检完成：%s正常 %d%s · %s注意 %d%s · %s危险 %d%s\n' "$C_G" "$N_OK" "$C_0" "$C_Y" "$N_WARN" "$C_0" "$C_R" "$N_BAD" "$C_0"
  echo "本工具只做本机检查，无法证明公网实际可达性；云服务器还要核对服务商控制台的安全组。"
}

case ${1:-full} in
  full)
    check_ports
    check_docker
    check_ssh
    check_f2b
    check_system
    check_panel
    check_vw
    summary
    ;;
  ports) check_ports ;;
  docker) check_docker ;;
  *) die "未知参数：$1" ;;
esac
exit 0
