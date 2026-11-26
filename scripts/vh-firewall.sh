#!/usr/bin/env bash
# 防火墙规则管理：直接读写 1Panel 使用的 iptables 链（1PANEL_BASIC）或 UFW。
# 实时规则就是唯一的数据来源，vhm 不另存规则清单，所以 1Panel 页面和 vhm 看到的始终一致。
# vhm 创建的规则带注释「vhm:<编号> 备注」，删除只针对这些规则；其他规则仍在 1Panel 中管理。
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"
FW_CHAIN=1PANEL_BASIC
UFW_DIR=${UFW_DIR:-/etc/ufw}
FW_UNDO=""
R_FAMILY=() R_POS=() R_RAW=() R_ID=() UFW_ROWS=()

record_undo() { # 记录撤销步骤；回滚执行时 FW_UNDO 为空，不再记录
  [[ -n $FW_UNDO ]] || return 0
  local IFS=$'\t'
  printf '%s\n' "$*" >>"$FW_UNDO"
}

backend() {
  case $(fw_type) in
    1panel-iptables) echo iptables ;;
    ufw) echo ufw ;;
    *) echo unsupported ;;
  esac
}

backend_label() {
  case $1 in
    iptables) echo "1Panel · iptables" ;;
    ufw) echo "UFW" ;;
    *) echo "不支持" ;;
  esac
}

# 1Panel 把持久规则存在「安装目录/1panel/firewall」，启动时从这里恢复 1PANEL_BASIC 链
firewall_dir() {
  local configured base
  configured=$(conf_get PANEL_FIREWALL_DIR || true)
  if [[ -n $configured && -d $configured ]]; then echo "$configured"; return 0; fi
  base=$(awk -F= '$1 == "BASE_DIR" { print $2; exit }' /usr/local/bin/1pctl 2>/dev/null | tr -d "\"' ")
  if [[ -n $base && -d $base/1panel/firewall ]]; then echo "$base/1panel/firewall"; return 0; fi
  if [[ -d /opt/1panel/firewall ]]; then echo /opt/1panel/firewall; return 0; fi
  return 1
}

family_bin() { if [[ $1 == ipv6 ]]; then echo ip6tables; else echo iptables; fi; }
have_family() { "$(family_bin "$1")" -w -S "$FW_CHAIN" >/dev/null 2>&1; }

source_family() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    sys.exit(1)
print("ipv%d" % net.version)
PY
}

# 归一化来源：主机位带前缀（如 1.2.3.4/24）按网络地址输出，单主机保持原样
source_normalize() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    sys.exit(1)
print(net.network_address if net.prefixlen == net.max_prefixlen else net)
PY
}

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

# ---------- iptables（1Panel） ----------
fw_field() { # fw_field 文本 正则：输出第一个捕获组
  local re=$2
  [[ $1 =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

fw_describe() { # 把 iptables -S 的一行转成「动作 协议 端口 来源 备注」
  local line=$1 head action proto port source comment iface state
  head=${line%%--comment*}
  action=$(fw_field "${line##*-j }" '^([A-Z]+)')
  proto=$(fw_field "$head" ' -p ([a-z0-9-]+)')
  port=$(fw_field "$head" ' --dports? ([0-9:,]+)')
  source=$(fw_field "$head" ' -s ([^ ]+)')
  iface=$(fw_field "$head" ' -i ([^ ]+)')
  state=$(fw_field "$head" ' --ctstate ([^ ]+)')
  [[ -n $state ]] || state=$(fw_field "$head" ' --state ([^ ]+)')
  if [[ $iface == lo ]]; then
    source="本机 loopback"
  elif [[ -n $iface ]]; then
    source="接口 $iface${source:+ / $source}"
  fi
  [[ -z $state ]] || source="${source:-所有 IP} / $state"
  comment=$(fw_field "$line" '--comment ("[^"]*"|[^ ]+)')
  comment=${comment//\"/}
  case $action in
    ACCEPT) action=允许 ;;
    DROP | REJECT) action=拒绝 ;;
  esac
  printf '%-4s %-5s %-12s %-30s %s' "$action" "${proto:-all}" "${port:--}" "${source:-所有 IP}" "$comment"
}

load_iptables_rules() { # 读取两个地址族的 1PANEL_BASIC 链，位置号与 iptables 中的顺序一致
  R_FAMILY=() R_POS=() R_RAW=() R_ID=()
  local family output line pos id re='--comment "?vhm:([0-9]{17})'
  for family in ipv4 ipv6; do
    output=$("$(family_bin "$family")" -w -S "$FW_CHAIN" 2>/dev/null) || continue
    pos=0
    while IFS= read -r line; do
      [[ $line == "-A $FW_CHAIN "* ]] || continue
      pos=$((pos + 1))
      id=""
      [[ $line =~ $re ]] && id=${BASH_REMATCH[1]}
      R_FAMILY+=("$family") R_POS+=("$pos") R_RAW+=("$line") R_ID+=("$id")
    done <<<"$output"
  done
}

ipt_apply_line() { # ipt_apply_line 地址族 规则行：用 restore 执行一条 -A/-D/-I，原子且能拿到错误
  printf '*filter\n%s\nCOMMIT\n' "$2" | "$(family_bin "$1")-restore" -w --noflush
}

ipt_has_line() { # 先完整读取再匹配：grep -q 提前退出会让大链触发 SIGPIPE，pipefail 下误判为失败
  local out
  out=$("$(family_bin "$1")" -w -S "$FW_CHAIN" 2>/dev/null) || return 1
  grep -Fxq -- "$2" <<<"$out"
}

# 与 1Panel 的保存逻辑相同：只写链中的 -A 行，保留原权限，临时文件改名替换
persist_chain() {
  local family=$1 dir file tmp output mode=644
  dir=$(firewall_dir) || { log_err "找不到 1Panel 防火墙目录，可在配置文件中设置 PANEL_FIREWALL_DIR"; return 1; }
  file=$dir/1panel_basic.rules
  [[ $family == ipv6 ]] && file=$dir/ipv6_1panel_basic.rules
  output=$("$(family_bin "$family")" -w -S "$FW_CHAIN" 2>/dev/null) || { log_err "读取 $family $FW_CHAIN 链失败"; return 1; }
  [[ -e $file ]] && mode=$(stat -c %a "$file")
  tmp=$(mktemp "$dir/.1panel_basic.rules.vhm-XXXXXX") || return 1
  if ! { awk -v chain="$FW_CHAIN" '$1 == "-A" && $2 == chain' <<<"$output" >"$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$file"; }; then
    rm -f -- "$tmp"
    log_err "写入 1Panel 持久规则文件失败：$file"
    return 1
  fi
}

ipt_add() { # ipt_add 地址族 动作 协议 端口 来源 位置 编号 注释
  local family=$1 target=ACCEPT bin raw
  local -a args=(-p "$3")
  [[ $2 == deny ]] && target=DROP
  [[ $5 == any ]] || args+=(-s "$5")
  args+=(-m "$3" --dport "$4" -m comment --comment "$8" -j "$target")
  bin=$(family_bin "$family")
  firewall_dir >/dev/null || { log_err "找不到 1Panel 防火墙目录，可在配置文件中设置 PANEL_FIREWALL_DIR"; return 1; }
  if (($6 > 0)); then
    "$bin" -w -I "$FW_CHAIN" "$6" "${args[@]}" || { log_err "写入 $family 规则失败（位置是否超过现有规则数？）"; return 1; }
  else
    "$bin" -w -A "$FW_CHAIN" "${args[@]}" || { log_err "写入 $family 规则失败"; return 1; }
  fi
  raw=$("$bin" -w -S "$FW_CHAIN" | grep -F -m1 -- "vhm:$7")
  [[ -n $raw ]] || { log_err "规则写入后未能在 $FW_CHAIN 中找到"; return 1; }
  record_undo delete "$family" 0 "$raw" || { ipt_apply_line "$family" "${raw/#-A /-D }"; log_err "无法写入回滚记录"; return 1; }
  persist_chain "$family"
}

# ---------- UFW ----------
load_ufw_rows() { # 从 UFW 持久规则读取 vhm 规则：编号 动作 协议 端口 来源 注释
  UFW_ROWS=()
  mapfile -t UFW_ROWS < <(python3 - "$UFW_DIR" <<'PY'
import sys
seen = set()
for name in ("user.rules", "user6.rules"):
    try:
        lines = open(f"{sys.argv[1]}/{name}", encoding="utf-8").read().splitlines()
    except OSError:
        continue
    for line in lines:
        if not line.startswith("### tuple ### "):
            continue
        parts = line[len("### tuple ### "):].split()
        comment = ""
        for part in parts:
            if part.startswith("comment="):
                try:
                    comment = bytes.fromhex(part[8:]).decode("utf-8")
                except ValueError:
                    comment = ""
        if len(parts) < 7 or not comment.startswith("vhm:"):
            continue
        action, proto, port, _dst, _sport, source = parts[:6]
        rule_id = comment[4:].split(" ", 1)[0]
        if rule_id in seen:
            continue
        seen.add(rule_id)
        if source in ("0.0.0.0/0", "::/0"):
            source = "any"
        print("\t".join([rule_id, action, proto, port, source, comment]))
PY
  )
}

ufw_spec() { printf '%s\n' "$1" from "$4" to any port "$3" proto "$2"; } # ufw_spec 动作 协议 端口 来源

# 从 ufw status numbered 中找出带指定 vhm 标记的规则编号（v4 / v6 各一条时都会列出）
ufw_comment_numbers() {
  local id=$1
  ufw_run status numbered 2>/dev/null | awk -v marker="vhm:$id" '
    { n = "" }
    match($0, /^\[[[:space:]]*[0-9]+\]/) {
      n = substr($0, RSTART + 1, RLENGTH - 2)
      gsub(/[^0-9]/, "", n)
    }
    n != "" && (index($0, "# " marker) || index($0, "#" marker)) { print n }
  '
}

ufw_del_comment() { # ufw_del_comment 规则ID [必须存在=1]：只按 vhm 标记删除，不按同条件规则删除
  local id=$1 required=${2:-0} n
  local -a nums=()
  mapfile -t nums < <(ufw_comment_numbers "$id" | sort -rn)
  if ((${#nums[@]} == 0)); then
    if ((required)); then
      log_err "UFW 中找不到 vhm:$id 的规则（可能已在 1Panel 中删除），请刷新后重试"
      return 1
    fi
    log_info "UFW 中已没有 vhm:$id 的规则"
    return 0
  fi
  for n in "${nums[@]}"; do
    ufw_run --force delete "$n" || { log_err "UFW 删除第 $n 条规则失败"; return 1; }
  done
  if [[ -n $(ufw_comment_numbers "$id") ]]; then
    log_err "删除后仍能查到 vhm:$id，请检查 UFW 状态"
    return 1
  fi
  log_ok "已删除 UFW 规则 vhm:$id（${#nums[@]} 条）"
}

ufw_add() { # ufw_add 动作 协议 端口 来源 位置 注释
  local out id=${6#vhm:}
  id=${id%% *}
  local -a spec
  mapfile -t spec < <(ufw_spec "$1" "$2" "$3" "$4")
  if (($5 > 0)); then
    out=$(ufw_run insert "$5" "${spec[@]}" comment "$6" 2>&1) || { log_err "UFW 添加失败：$out"; return 1; }
  else
    out=$(ufw_run "${spec[@]}" comment "$6" 2>&1) || { log_err "UFW 添加失败：$out"; return 1; }
  fi
  echo "$out" | sed 's/^/  /'
  if [[ $out == *Skipping* && $out != *added* ]]; then
    if [[ -n $(ufw_comment_numbers "$id") ]]; then
      log_info "已存在相同的 vhm 规则，未重复添加"
      return 0
    fi
    log_warn "UFW 中已有相同条件但不是 vhm 创建的规则，未重复添加；请先在 1Panel 中确认"
    return 1
  fi
  if [[ -z $(ufw_comment_numbers "$id") ]]; then
    log_err "UFW 添加后未找到 vhm:$id 标记"
    return 1
  fi
  record_undo ufw-delete "$6" || { ufw_del_comment "$id"; log_err "无法写入回滚记录"; return 1; }
}

# ---------- 界面 ----------
show_iptables_chains() {
  local family chain output line mark found
  for family in ipv4 ipv6; do
    for chain in 1PANEL_BASIC_BEFORE 1PANEL_BASIC 1PANEL_BASIC_AFTER; do
      output=$("$(family_bin "$family")" -w -S "$chain" 2>/dev/null) || continue
      echo "  [$family · $chain]"
      found=0
      while IFS= read -r line; do
        [[ $line == "-A $chain "* ]] || continue
        found=1
        mark=""
        [[ $line =~ vhm:[0-9]{17} ]] && mark="  ← vhm"
        printf '    %s%s\n' "$(fw_describe "$line")" "$mark"
      done <<<"$output"
      ((found)) || echo "    （空）"
    done
  done
}

show_rules() {
  local be=$1
  if [[ $be == iptables ]]; then
    echo "  当前 1Panel 规则（按 INPUT 顺序：BEFORE → BASIC → AFTER）："
    printf '    %-4s %-5s %-12s %-30s %s\n' 动作 协议 端口 来源 备注
    show_iptables_chains
    echo "  vhm 新建规则写入 $FW_CHAIN；BEFORE / AFTER 是 1Panel 系统链，这里只读展示。"
  else
    ufw_run status numbered 2>/dev/null | sed 's/^/  /'
  fi
}

add_rule() {
  local be=$1 action proto port source family=ipv4 ans position remark id comment scope
  read -r -p "动作 [allow 允许 / deny 拒绝，默认 allow]: " action || return 0
  action=${action:-allow}
  [[ $action == allow || $action == deny ]] || { log_err "动作只能是 allow 或 deny"; return 1; }
  read -r -p "协议 [tcp/udp，默认 tcp]: " proto || return 0
  proto=${proto:-tcp}
  [[ $proto == tcp || $proto == udp ]] || { log_err "协议只能是 tcp 或 udp"; return 1; }
  read -r -p "端口（1-65535）: " port || return 0
  valid_port "$port" || { log_err "端口无效"; return 1; }
  port=$((10#$port))
  read -r -p "来源 IP 或网段（如 1.2.3.4、1.2.3.0/24；回车表示所有 IP）: " source || return 0
  source=${source:-any}
  if [[ $source != any ]]; then
    family=$(source_family "$source") || { log_err "来源不是有效的 IPv4 / IPv6 地址或网段"; return 1; }
    # 归一化后再下发与回显：1.2.3.4/24 实际放行的是整个 1.2.3.0/24 网段，按原文回显会误导确认
    source=$(source_normalize "$source") || { log_err "来源不是有效的 IPv4 / IPv6 地址或网段"; return 1; }
    scope=$source
  elif [[ $be == iptables ]] && have_family ipv6; then
    read -r -p "地址族 [4/6，默认 4]: " ans || return 0
    [[ $ans == 6 ]] && family=ipv6
    scope="所有 IP（$family）"
  else
    scope="所有 IP"
  fi
  read -r -p "插入位置（1 为最先匹配；回车追加到末尾）: " position || return 0
  position=${position:-0}
  [[ $position =~ ^[0-9]{1,4}$ ]] || { log_err "位置必须是数字"; return 1; }
  position=$((10#$position))
  read -r -p "备注（可空）: " remark || return 0
  remark=$(printf '%s' "$remark" | tr -d "\"'\\\\\t")
  remark=${remark:0:60}
  id="$(date +%y%m%d%H%M%S)$(printf '%05d' "$RANDOM")"
  comment="vhm:$id${remark:+ $remark}"
  echo
  echo "将在 $(backend_label "$be") 中添加：$action $proto/$port，来源 $scope，位置 ${position/#0/末尾}"
  confirm_yes "确认添加？" || return 0
  change_begin "防火墙：$action $proto/$port 来源 $scope" firewall
  FW_UNDO=$CHG_DIR/firewall-undo
  if [[ $be == iptables ]]; then
    ipt_add "$family" "$action" "$proto" "$port" "$source" "$position" "$id" "$comment"
  else
    ufw_add "$action" "$proto" "$port" "$source" "$position" "$comment"
  fi || { log_err "添加失败，正在撤销"; change_rollback "$CHG_ID"; return 1; }
  change_status applied
  log_ok "规则已生效并保存，1Panel 防火墙页面刷新即可看到（变更 $CHG_ID，可在 [25] 回滚）"
}

delete_rule() {
  local be=$1 n i action proto port source comment rule_id
  local -a pick=()
  echo
  echo "  vhm 创建的规则："
  if [[ $be == iptables ]]; then
    load_iptables_rules
    for i in "${!R_ID[@]}"; do
      [[ -n ${R_ID[$i]} ]] || continue
      pick+=("$i")
      printf '  [%d] %-6s %s\n' "${#pick[@]}" "${R_FAMILY[$i]}" "$(fw_describe "${R_RAW[$i]}")"
    done
  else
    load_ufw_rows
    for i in "${!UFW_ROWS[@]}"; do
      IFS=$'\t' read -r rule_id action proto port source comment <<<"${UFW_ROWS[$i]}"
      pick+=("$i")
      printf '  [%d] %-6s %-5s %-8s %-20s %s\n' "${#pick[@]}" "$action" "$proto" "$port" "$source" "$comment"
    done
  fi
  ((${#pick[@]})) || { log_info "没有 vhm 创建的规则。其他规则请在 1Panel 防火墙页面管理"; return 0; }
  read -r -p "输入要删除的序号（回车返回）: " n || return 0
  [[ -n $n ]] || return 0
  [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#pick[@]})) || { log_err "序号无效"; return 1; }
  i=${pick[$((n - 1))]}
  confirm_yes "确认删除第 $n 条规则？" || return 0
  if [[ $be == iptables ]]; then
    local family=${R_FAMILY[$i]} raw=${R_RAW[$i]}
    ipt_has_line "$family" "$raw" || { log_err "规则已被其他程序修改，请刷新后重试"; return 1; }
    change_begin "删除防火墙规则 vhm:${R_ID[$i]}" firewall
    FW_UNDO=$CHG_DIR/firewall-undo
    record_undo insert "$family" "${R_POS[$i]}" "$raw" || { change_rollback "$CHG_ID"; return 1; }
    ipt_apply_line "$family" "${raw/#-A /-D }" || { log_err "删除失败"; change_rollback "$CHG_ID"; return 1; }
    persist_chain "$family" || { change_rollback "$CHG_ID"; return 1; }
  else
    IFS=$'\t' read -r rule_id action proto port source comment <<<"${UFW_ROWS[$i]}"
    change_begin "删除防火墙规则 vhm:$rule_id" firewall
    FW_UNDO=$CHG_DIR/firewall-undo
    record_undo ufw-add "$action" "$proto" "$port" "$source" "$comment" || { change_rollback "$CHG_ID"; return 1; }
    ufw_del_comment "$rule_id" 1 || { change_rollback "$CHG_ID"; return 1; }
  fi
  change_status applied
  log_ok "规则已删除（变更 $CHG_ID，可在 [25] 回滚）"
}

menu() {
  local be choice
  while true; do
    be=$(backend)
    title "防火墙（$(backend_label "$be")）"
    if [[ $be == unsupported ]]; then
      log_err "未检测到 1Panel 的 iptables 防火墙或已启用的 UFW（当前识别为：$(fw_type)）"
      echo "请先在 1Panel →「主机」→「防火墙」中启用防火墙。"
      return 1
    fi
    show_rules "$be"
    echo
    echo "规则直接写入 $(backend_label "$be")，与 1Panel 防火墙页面实时一致。"
    echo "  [1] 添加规则   [2] 删除 vhm 创建的规则   [3] 刷新   [0] 返回"
    read -r -p "请选择：" choice || return 0
    case $choice in
      1) add_rule "$be" ;;
      2) delete_rule "$be" ;;
      3) ;;
      *) return 0 ;;
    esac
  done
}

# 回滚：按相反顺序撤销本次记录的每一步，只动这些规则，不覆盖之后新增的其他规则
restore() {
  local record=$1 rc=0 i kind a b c d e id
  local -a lines=() touched=()
  [[ -f $record/firewall-undo ]] || return 0
  mapfile -t lines <"$record/firewall-undo"
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r kind a b c d e <<<"${lines[$i]}"
    case $kind in
      delete)
        if ipt_has_line "$a" "$c"; then ipt_apply_line "$a" "${c/#-A /-D }" || rc=1; fi
        touched+=("$a")
        ;;
      insert)
        if ! ipt_has_line "$a" "$c"; then
          ipt_apply_line "$a" "${c/#-A $FW_CHAIN /-I $FW_CHAIN $b }" 2>/dev/null || ipt_apply_line "$a" "$c" || rc=1
        fi
        touched+=("$a")
        ;;
      ufw-delete)
        if [[ -n ${b:-} ]]; then
          id=${e#vhm:}
        else
          id=${a#vhm:}
        fi
        ufw_del_comment "${id%% *}" || rc=1
        ;;
      ufw-add) ufw_add "$a" "$b" "$c" "$d" 0 "$e" || rc=1 ;;
    esac
  done
  local family
  for family in ipv4 ipv6; do
    [[ " ${touched[*]} " == *" $family "* ]] || continue
    persist_chain "$family" || rc=1
  done
  return $rc
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case ${1:-menu} in
    menu) need_root; with_lock menu ;;
    restore)
      [[ -d ${2:-} ]] || exit 1
      restore "$2"
      ;;
    *) die "未知参数：$1" ;;
  esac
fi
