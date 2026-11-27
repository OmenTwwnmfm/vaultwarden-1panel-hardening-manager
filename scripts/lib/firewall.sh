# shellcheck shell=bash
# shellcheck disable=SC2034
# 防火墙后端识别与端口放行判断；由 vh-common.sh 加载，不要单独执行

# ---------- 防火墙 / Fail2Ban / sysctl ----------
# 防火墙规则由 1Panel 和 vhm [15] 共同管理，两者读写同一后端。1Panel（iptables）使用 1PANEL_BASIC_BEFORE / 1PANEL_BASIC /
# 1PANEL_BASIC_AFTER 三条链挂在 INPUT 上；系统端口放行通常在 BEFORE，用户规则在 BASIC，AFTER 末尾默认丢弃其余 TCP/UDP。
ufw_run() { LANGUAGE=en_US:en LC_ALL=C ufw "$@"; }
fw_type() {
  # 1Panel 的 iptables 后端优先：只要 INPUT 仍跳到 1PANEL_BASIC，vhm 就应与 1Panel 页面保持一致
  if command -v iptables >/dev/null 2>&1 && out_match '-j 1PANEL_BASIC' iptables -w -S INPUT; then
    echo 1panel-iptables
  elif command -v ufw >/dev/null 2>&1 && out_match 'Status: active' ufw_run status; then
    echo ufw
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo firewalld
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
    ufw) echo "UFW" ;;
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
      rules=$(ufw_run status 2>/dev/null | grep -E "^$p(/$proto)?[[:space:]]" | grep ALLOW || true)
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
      # 按 INPUT 中的实际匹配顺序检查三条 1Panel 链；ESTABLISHED/loopback 不算新连接放行
      rules=$(for chain in 1PANEL_BASIC_BEFORE 1PANEL_BASIC 1PANEL_BASIC_AFTER; do
        iptables -w -S "$chain" 2>/dev/null || true
      done | awk -v p="$p" -v proto="$proto" '
        /^-A / {
          if ($0 ~ / -i lo( |$)/) next
          if ($0 ~ /--(ct)?state /) {
            is_new = 0
            for (i = 1; i <= NF; i++) {
              if ($i == "--ctstate" || $i == "--state") {
                n = split($(i + 1), states, ",")
                for (j = 1; j <= n; j++) if (states[j] == "NEW") is_new = 1
              }
            }
            if (!is_new) next
          }
          has_proto = 0; proto_ok = 0; has_port = 0; port_ok = 0
          for (i = 1; i <= NF; i++) {
            if ($i == "-p") { has_proto = 1; if ($(i + 1) == proto) proto_ok = 1 }
            if ($i == "--dport" || $i == "--dports") {
              has_port = 1
              n = split($(i + 1), ports, ",")
              for (j = 1; j <= n; j++) {
                if (ports[j] == p) port_ok = 1
                else if (ports[j] ~ /^[0-9]+:[0-9]+$/) {
                  split(ports[j], bounds, ":")
                  if (p + 0 >= bounds[1] + 0 && p + 0 <= bounds[2] + 0) port_ok = 1
                }
              }
            }
          }
          if (has_proto && !proto_ok) next
          if (has_port && !port_ok) next
          target = ""
          for (i = 1; i <= NF; i++) if ($i == "-j") target = $(i + 1)
          if (target == "ACCEPT" || target == "DROP" || target == "REJECT") {
            print target " " $0
            exit
          }
        }')
      if [[ -z $rules ]]; then
        echo none
      elif [[ $rules == ACCEPT* ]]; then
        if [[ $rules == *" -s "* ]]; then echo limited; else echo all; fi
      elif [[ $rules == DROP* || $rules == REJECT* ]]; then
        echo none
      else
        echo unknown
      fi
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
    log_warn "防火墙尚未放行 $p/tcp。请在 1Panel →「主机」→「防火墙」或 vhm [15] 中放行端口 $p，协议 TCP。"
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

# 只读列出 1Panel（iptables）三条链的端口规则：链 动作 协议 端口 来源
panel_fw_rules() {
  local chain out
  for chain in 1PANEL_BASIC_BEFORE 1PANEL_BASIC 1PANEL_BASIC_AFTER; do
    out=$(iptables -w -S "$chain" 2>/dev/null) || continue
    awk -v chain="$chain" '$1 == "-A" {
      act = "?"; proto = "all"; port = "-"; src = "所有 IP"; iface = ""; state = ""
      for (i = 3; i <= NF; i++) {
        if ($i == "-j") act = $(i + 1)
        else if ($i == "-p") proto = $(i + 1)
        else if ($i == "--dport" || $i == "--dports") port = $(i + 1)
        else if ($i == "-s") src = $(i + 1)
        else if ($i == "-i") iface = $(i + 1)
        else if ($i == "--ctstate" || $i == "--state") state = $(i + 1)
      }
      sub(/\/32$/, "", src)
      if (iface == "lo") src = "本机 loopback"
      else if (iface != "") src = "接口 " iface (src == "所有 IP" ? "" : " / " src)
      if (state != "") src = src " / " state
      if (act == "ACCEPT") act = "允许"; else if (act == "DROP" || act == "REJECT") act = "拒绝"
      printf "  %-22s %-6s %-5s %-14s %s\n", chain, act, proto, port, src
    }' <<<"$out"
  done
}
