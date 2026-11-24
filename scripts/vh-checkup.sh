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

# ---------- 端口与放行规则 ----------
listen_table() {
  title "监听端口"
  command -v ss >/dev/null 2>&1 || { log_warn "未安装 ss（iproute2），无法列出端口"; return 0; }
  printf '  %-5s %-28s %-8s %s\n' 协议 地址 范围 进程
  ss -H -tulpn 2>/dev/null | awk '{ print $1, $5, $7 }' | sort -u -k2 | while read -r proto addr proc; do
    local host=${addr%:*} scope
    proc=$(sed -nE 's/.*\(\("([^"]+)".*/\1/p' <<<"$proc")
    if [[ $host == 127.* || $host == '[::1]' || $host == *%lo ]]; then scope=本机; elif public_addr "$host"; then scope=所有地址; else scope=指定地址; fi
    printf '  %-5s %-28s %-8s %s\n' "$proto" "$addr" "$scope" "${proc:--}"
  done
}

fw_rules() {
  title "防火墙放行规则"
  local fw
  fw=$(fw_type)
  case $fw in
    ufw)
      ufw status verbose 2>/dev/null | sed -n '/^Default/p'
      ufw status 2>/dev/null | sed -n '/^To/,$p' | sed 's/^/  /'
      ;;
    firewalld)
      firewall-cmd --list-all 2>/dev/null | sed 's/^/  /'
      ;;
    nftables) nft list ruleset 2>/dev/null | grep -E 'hook input|dport|saddr' | sed 's/^[[:space:]]*/  /' | head -n 40 ;;
    iptables) iptables -S INPUT 2>/dev/null | sed 's/^/  /' | head -n 40 ;;
    none) echo "  未检测到启用的主机防火墙" ;;
  esac
  [[ -d /opt/1panel && $fw != none ]] && echo "  （端口规则请在 1Panel →「主机」→「防火墙」中修改）"
}

check_ports() {
  title "端口暴露"
  local fw proto addr host port proc pub=()
  fw=$(fw_type)
  if [[ $fw == none ]]; then
    chk bad "主机防火墙" "未启用，所有监听在所有地址上的端口都对公网开放" "在 1Panel →「主机」→「防火墙」启用，并只放行需要的端口"
  else
    chk ok "主机防火墙" "$fw 已启用"
  fi
  command -v ss >/dev/null 2>&1 || return 0
  while read -r proto addr proc; do
    host=${addr%:*} port=${addr##*:}
    public_addr "$host" || continue
    proc=$(sed -nE 's/.*\(\("([^"]+)".*/\1/p' <<<"$proc")
    pub+=("$port/${proto}(${proc:-?})")
  done < <(ss -H -tulpn 2>/dev/null | awk '{ print $1, $5, $7 }' | sort -u)
  if ((${#pub[@]})); then
    chk warn "监听所有地址的端口" "$(printf '%s ' "${pub[@]}" | sort -u)" "逐个确认是否需要对外；不需要的改为只监听 127.0.0.1，或在防火墙中只放行指定 IP"
  else
    chk ok "监听所有地址的端口" "无"
  fi
}

# ---------- Docker 暴露 ----------
check_docker() {
  title "Docker 端口暴露"
  command -v docker >/dev/null 2>&1 || { chk ok "Docker" "未安装"; return 0; }
  local name binds b ip found=0 seen
  ip=$(hostname -I 2>/dev/null | awk '{ print $1 }')
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
      chk bad "容器 $name" "端口 $port 发布在所有地址上$proof；Docker 会绕过 ufw/firewalld，防火墙拦不住" \
        "在 1Panel →「容器」或「已安装应用」→ 参数中取消「端口外部访问」，改为只监听 127.0.0.1，由 OpenResty 反代"
    done
  done < <(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | sed 's/, / /g')
  ((found)) || chk ok "容器端口" "没有容器把端口发布在所有地址上"
}

# ---------- SSH ----------
check_ssh() {
  title "SSH"
  local eff pa prl port
  eff=$(sshd_eff)
  if [[ -z $eff ]]; then
    chk warn "SSH 配置" "无法读取 sshd -T" "检查 sshd 配置：sshd -t"
    return 0
  fi
  pa=$(awk '$1 == "passwordauthentication" { print $2 }' <<<"$eff")
  prl=$(awk '$1 == "permitrootlogin" { print $2 }' <<<"$eff")
  port=$(awk '$1 == "port" { print $2 }' <<<"$eff" | paste -sd' ')
  if [[ $port == 22 ]]; then chk warn "SSH 端口" "22（默认端口，扫描最多）" "可在 [05] 修改"; else chk ok "SSH 端口" "$port"; fi
  if [[ $pa == yes ]]; then chk bad "密码登录" "已开启" "只用密钥登录：启用 [06] 2FA 时会自动关闭密码登录"; else chk ok "密码登录" "已关闭"; fi
  if tfa_enabled; then
    chk ok "SSH 2FA" "已启用（密钥 + 动态口令），root 登录：$prl"
  else
    chk warn "SSH 2FA" "未启用，root 登录：$prl" "在 [06] 启用 密钥 + 动态口令"
  fi
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
    chk warn "Fail2Ban" "未安装" "在 [11] 安装并配置 SSH 防护"
  elif ! systemctl is-active --quiet fail2ban; then
    chk bad "Fail2Ban" "已安装但未运行" "systemctl enable --now fail2ban，或在 [11] 重新配置"
  elif ! fail2ban-client status sshd >/dev/null 2>&1; then
    chk warn "Fail2Ban" "运行中，但没有 sshd 防护" "在 [11] 配置"
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
    chk warn "自动安全更新" "未启用" "在 [18] 启用"
  fi
  local bad=() k want v
  for k in net.ipv4.tcp_syncookies=1 net.ipv4.conf.all.rp_filter=1 net.ipv4.conf.all.accept_redirects=0 net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.all.accept_source_route=0; do
    want=${k#*=} k=${k%%=*}
    v=$(sysctl -n "$k" 2>/dev/null) || continue
    [[ $k == *rp_filter && $v == 2 ]] && continue
    [[ $v == "$want" ]] || bad+=("$k=$v")
  done
  if ((${#bad[@]})); then chk warn "内核网络参数" "${bad[*]}" "在 [19] 加固"; else chk ok "内核网络参数" "已加固"; fi
  if [[ -f /var/run/reboot-required ]]; then chk warn "重启" "有更新需要重启才能生效" "择机重启 VPS"; fi
}

# ---------- 1Panel ----------
check_panel() {
  [[ -d /opt/1panel ]] || command -v 1pctl >/dev/null 2>&1 || return 0
  title "1Panel 面板"
  local info port entrance
  info=$(1pctl user-info 2>/dev/null || true)
  if [[ -z $info ]]; then
    chk warn "1Panel" "无法读取 1pctl user-info" "确认 1pctl 可用"
    return 0
  fi
  port=$(sed -nE 's/.*(端口|port)[^0-9]*([0-9]+).*/\2/Ip' <<<"$info" | head -n1)
  entrance=$(sed -nE 's/.*(安全入口|entrance)[:：][[:space:]]*(.*)/\2/Ip' <<<"$info" | head -n1)
  if [[ -n $port ]] && ss -ltnH 2>/dev/null | awk '{ print $4 }' | grep -Eq "^(0\.0\.0\.0|\*|\[::\]):$port$"; then
    chk warn "面板端口" "$port 监听所有地址" "在 1Panel 防火墙中只对你的 IP 放行面板端口"
  else
    chk ok "面板端口" "${port:-?}"
  fi
  if [[ -z $entrance ]]; then chk bad "安全入口" "未设置" "1Panel →「面板设置」→「安全」设置安全入口"; else chk ok "安全入口" "已设置"; fi
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
  if [[ $sig == false ]]; then chk ok "开放注册" "已关闭"; else chk bad "开放注册" "已开启，任何人都能注册" "在 [14] 关闭"; fi
  case $(vw_admin_state) in
    off) chk ok "后台 /admin" "已关闭" ;;
    argon2) chk warn "后台 /admin" "已开启（argon2 哈希令牌）" "不用时在 [15] 关闭，或在 OpenResty 中限制 /admin 的来源 IP" ;;
    plain) chk bad "后台 /admin" "已开启，令牌为明文保存" "在 [15] 更换为 argon2 哈希令牌" ;;
    notoken) chk bad "后台 /admin" "免令牌访问（DISABLE_ADMIN_TOKEN=true）" "在 [15] 关闭或设置令牌" ;;
  esac
  domain=$(vw_eff domain DOMAIN "")
  if [[ $domain == https://* ]]; then chk ok "DOMAIN" "$domain"; else chk bad "DOMAIN" "${domain:-未设置}（非 https）" "1Panel 网站中为该域名启用 HTTPS，并在应用参数中设置 https:// 域名"; fi
  local loose=() p m
  while IFS= read -r p; do
    m=$(stat -c '%a' "$p") || continue
    (((8#$m & 8#007) != 0)) && loose+=("${p#"$VW_DATA_DIR"/}:$m")
  done < <(vw_sensitive_paths)
  if ((${#loose[@]})); then chk warn "数据目录权限" "其他用户可访问：${loose[*]}" "chmod -R o-rwx $VW_DATA_DIR"; else chk ok "数据目录权限" "其他用户无权限"; fi
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
    chk bad "备份（vbm）" "未安装 vaultwarden-1panel-backup-manager" "安装 vbm 并配置自动备份"
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
  ports)
    listen_table
    fw_rules
    check_ports
    ;;
  docker) check_docker ;;
  *) die "未知参数：$1" ;;
esac
exit 0
