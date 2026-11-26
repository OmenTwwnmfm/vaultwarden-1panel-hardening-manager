#!/usr/bin/env bash
# 1Panel 面板：状态、端口、用户名 / 密码、监听地址、服务启停、应急重置
# 全部通过 1Panel 自带的 1pctl 完成（按 1Panel v2 的子命令实现），vhm 不直接修改 1Panel 数据库。
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

need_panel() {
  panel_installed || { log_err "未找到 1pctl，本机似乎没有安装 1Panel"; exit 1; }
}

mask() { # 安全入口只显示前 2 位
  local s=$1
  ((${#s} <= 2)) && { echo "$s"; return; }
  printf '%s%s\n' "${s:0:2}" "$(printf '*%.0s' $(seq 3 "${#s}"))"
}

panel_listen_mode() { # 当前监听方式：ipv6（[::]，同时接受 IPv4）/ ipv4 / unknown
  local p=$1 l
  l=$(ss -ltnH "sport = :$p" 2>/dev/null | awk '{ print $4 }')
  if grep -q '^\[::\]:' <<<"$l"; then echo ipv6; elif grep -q '^0\.0\.0\.0:' <<<"$l"; then echo ipv4; elif [[ -n $l ]]; then echo specific; else echo unknown; fi
}

show_status() {
  need_panel
  title "1Panel 面板状态"
  local url port entrance u scope
  url=$(panel_url)
  port=$(panel_port_of "$url")
  entrance=$(panel_entrance_of "$url")
  printf '  %-14s %s\n' "版本" "$(panel_version || echo 未知)"
  for u in $(panel_units); do
    printf '  %-14s %s\n' "服务 $u" "$(systemctl is-active "$u" 2>/dev/null)"
  done
  printf '  %-14s %s\n' "面板端口" "${port:-未知}"
  printf '  %-14s %s\n' "安全入口" "$([[ -n $entrance ]] && echo "已设置（$(mask "$entrance")）" || echo 未设置)"
  printf '  %-14s %s\n' "访问协议" "$([[ $url == https://* ]] && echo HTTPS || echo HTTP)"
  [[ -n $port ]] && printf '  %-14s %s\n' "监听方式" "$(panel_listen_mode "$port")"
  if [[ -n $port ]]; then
    scope=$(port_scope "$port")
    case $scope in
      all) log_warn "面板端口 $port 在防火墙（$(fw_label)）中对所有 IP 放行。建议在 1Panel 防火墙中只放行你的 IP，或设置「授权 IP」" ;;
      limited) log_ok "面板端口 $port 只对指定 IP 放行" ;;
      none) log_info "防火墙中没有放行面板端口 $port 的规则（可能通过端口范围或安全组放行）" ;;
      *) log_info "无法判断面板端口的放行范围（防火墙：$(fw_label)）" ;;
    esac
  fi
  if 1pctl user-list >/dev/null 2>&1; then
    echo
    echo "  面板用户："
    timeout 20 1pctl user-list 2>/dev/null | sed 's/^/    /'
  fi
  if [[ $(fw_type) == 1panel-iptables ]]; then
    echo
    echo "  1Panel 防火墙端口规则（只读，修改可在 1Panel →「主机」→「防火墙」或 vhm [15]）："
    printf '  %-22s %-6s %-5s %-14s %s\n' 链 动作 协议 端口 来源
    panel_fw_rules || echo "  （读取失败）"
  fi
  echo
  echo "两步验证、授权 IP、访问域名等更多设置请在 1Panel →「面板设置」→「安全」中查看。"
}

change_port() {
  need_panel
  title "修改 1Panel 面板端口"
  local url cur new
  url=$(panel_url)
  cur=$(panel_port_of "$url")
  [[ -n $cur ]] || { log_err "无法读取当前面板端口（1pctl user-info）"; return 1; }
  echo "当前端口：$cur"
  read -r -p "新端口（1024-65535，回车取消）: " new || return 0
  [[ -n $new ]] || return 0
  [[ $new =~ ^[0-9]+$ ]] && ((new >= 1024 && new <= 65535)) || { log_err "端口需在 1024-65535 之间"; return 1; }
  [[ $new == "$cur" ]] && { log_info "端口未变化"; return 0; }
  [[ -z $(ss -ltnH "sport = :$new" 2>/dev/null) ]] || { log_err "端口 $new 已被占用"; return 1; }
  wait_port_allowed "$new" || { log_info "已取消"; return 0; }
  echo
  echo "修改后面板会自动重启，访问地址变为：${url/:$cur/:$new}"
  confirm_yes "确认把面板端口从 $cur 改为 $new？" || return 0
  change_begin "1Panel 面板端口 $cur → $new" panel
  printf 'PORT="%s"\n' "$cur" >"$CHG_DIR/panel.prev"
  if ! panel_set_port "$new"; then
    log_err "修改失败或面板未在新端口启动，正在恢复"
    change_rollback "$CHG_ID"
    return 1
  fi
  change_status applied
  log_ok "面板端口已改为 $new（变更 $CHG_ID，可在 [25] 回滚）"
  echo "确认能用新地址登录后，可在 1Panel 防火墙中删除旧端口 $cur 的放行规则。"
}

gen_password() { head -c 24 /dev/urandom | base64 | tr -d '/+=\n' | head -c 20; }

change_account() {
  need_panel
  title "修改 1Panel 用户名 / 密码"
  log_warn "这项修改无法回滚（vhm 不保存旧的用户名和密码）。修改后请立即更新密码管理器中的记录。"
  echo "  [1] 修改用户名"
  echo "  [2] 修改密码"
  echo "  [0] 返回"
  local c
  read -r -p "请选择：" c || return 0
  case $c in
    1)
      confirm_yes "修改面板用户名？接下来由 1pctl 直接提示输入" || return 0
      1pctl update username || { log_err "修改失败"; return 1; }
      log_info "已修改面板用户名"
      ;;
    2)
      local g
      read -r -p "需要 vhm 生成一个 20 位随机密码供你粘贴吗？[Y/n] " g || return 0
      if [[ ${g,,} != n ]]; then
        printf '\n%s建议密码（只显示这一次，请先保存到密码管理器）：%s\n\n    %s\n\n' "$C_Y" "$C_0" "$(gen_password)"
      fi
      confirm_yes "修改面板密码？接下来由 1pctl 提示输入两次（输入时不显示）" || return 0
      1pctl update password || { log_err "修改失败"; return 1; }
      log_info "已修改面板密码"
      ;;
  esac
}

change_listen() {
  need_panel
  title "切换面板监听地址"
  local port cur want
  port=$(panel_port_of "$(panel_url)")
  cur=$(panel_listen_mode "${port:-0}")
  echo "当前：$cur（ipv6 表示监听 [::]，同时接受 IPv4 与 IPv6 连接）"
  echo "  [1] 只监听 IPv4   [2] 监听 IPv6（同时接受 IPv4）   [0] 返回"
  local c
  read -r -p "请选择：" c || return 0
  case $c in
    1) want=ipv4 ;;
    2) want=ipv6 ;;
    *) return 0 ;;
  esac
  [[ $want == "$cur" ]] && { log_info "已经是 $want"; return 0; }
  if [[ $cur != ipv4 && $cur != ipv6 ]]; then
    log_warn "当前监听模式为 $cur（具体地址或未知），变更记录无法保存该值：日后回滚只能恢复端口，不能自动恢复监听方式"
  fi
  confirm_yes "把面板切换为监听 $want？面板会重启" || return 0
  change_begin "1Panel 面板监听 $cur → $want" panel
  [[ $cur == ipv4 || $cur == ipv6 ]] && printf 'LISTEN="%s"\n' "$cur" >"$CHG_DIR/panel.prev"
  if ! panel_listen "$want" || ! panel_wait_port "${port:-0}"; then
    log_err "切换失败，正在恢复"
    change_rollback "$CHG_ID"
    return 1
  fi
  change_status applied
  log_ok "已切换为 $want（变更 $CHG_ID，可在 [25] 回滚）"
}

service_menu() {
  need_panel
  title "1Panel 服务"
  local units u
  mapfile -t units < <(panel_units)
  ((${#units[@]})) || { log_err "未找到 1Panel 的 systemd 服务"; return 1; }
  for u in "${units[@]}"; do printf '  %-16s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done
  echo
  echo "  [1] 启动   [2] 停止   [3] 重启   [0] 返回"
  local c act
  read -r -p "请选择：" c || return 0
  case $c in
    1) act=start ;;
    2) act=stop ;;
    3) act=restart ;;
    *) return 0 ;;
  esac
  [[ $act == stop ]] && log_warn "停止后 1Panel 面板、计划任务和应用商店管理都不可用；已运行的网站和容器不受影响"
  confirm_yes "确认 $act 1Panel（${units[*]}）？" || return 0
  if [[ $act == stop ]]; then
    # 先停 agent 再停 core，启动顺序相反
    for ((u = ${#units[@]} - 1; u >= 0; u--)); do systemctl stop "${units[$u]}" || return 1; done
  else
    for u in "${units[@]}"; do systemctl "$act" "$u" || return 1; done
  fi
  log_ok "已执行 $act"
}

RESET_ITEMS=(entrance ips domain https mfa passkey)
reset_desc() {
  case $1 in
    entrance) echo "取消安全入口（任何人只要知道地址和端口就能打开登录页）" ;;
    ips) echo "取消授权 IP 限制（所有 IP 都能访问面板）" ;;
    domain) echo "取消访问域名绑定（可以直接用 IP 访问）" ;;
    https) echo "取消面板 HTTPS（改回 HTTP 明文访问）" ;;
    mfa) echo "取消面板两步验证" ;;
    passkey) echo "清除面板通行密钥（Passkey）" ;;
  esac
}

reset_menu() {
  need_panel
  title "1Panel 应急重置"
  log_warn "以下操作会降低面板安全性，只在被面板挡在外面（忘记安全入口、换了 IP、两步验证设备丢失等）时使用。"
  log_warn "重置无法回滚。恢复访问后请立即在 1Panel →「面板设置」→「安全」中重新设置。"
  echo
  local avail items=() i=0 it
  avail=" $(reset_available) "
  for it in "${RESET_ITEMS[@]}"; do
    [[ $avail == *" $it "* ]] && items+=("$it")
  done
  if ((${#items[@]} == 0)); then
    log_warn "没能从 1pctl reset 的帮助中识别出子命令，下面按 1Panel v2 列出；不支持的项执行时会报错，不会造成修改"
    items=("${RESET_ITEMS[@]}")
  fi
  for it in "${items[@]}"; do
    i=$((i + 1))
    printf '  [%d] %-9s %s\n' "$i" "$it" "$(reset_desc "$it")"
  done
  echo "  [0] 返回"
  local c ans
  read -r -p "请选择：" c || return 0
  [[ $c =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#items[@]})) || return 0
  it=${items[$((c - 1))]}
  echo
  echo "将执行：1pctl reset $it —— $(reset_desc "$it")"
  read -r -p "请输入「$it」确认（其他输入均取消）: " ans || return 0
  [[ $ans == "$it" ]] || { log_info "已取消"; return 0; }
  timeout 60 1pctl reset "$it" || { log_err "重置失败"; return 1; }
  log_ok "已执行 1pctl reset $it"
  _log_file WARN "1Panel 应急重置：$it"
}

case ${1:-status} in
  status) need_root; show_status ;;
  port) need_root; with_lock change_port ;;
  account) need_root; with_lock change_account ;;
  listen) need_root; with_lock change_listen ;;
  service) need_root; with_lock service_menu ;;
  reset) need_root; with_lock reset_menu ;;
  *) die "未知参数：$1" ;;
esac
