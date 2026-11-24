#!/usr/bin/env bash
# Vaultwarden 管理：状态、注册、后台 ADMIN、用户列表、安全选项
# 所有修改写入数据目录的 config.json（优先于 1Panel 应用参数，且 1Panel 升级/重建不会覆盖）
# 修改流程：vbm 完整备份 → 记录原 config.json → 写入 → 重启容器 → 健康检查；失败自动恢复
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

need_instance() {
  load_instance || { log_err "未能确定 Vaultwarden 实例，请先运行 [01]"; exit 1; }
}

onoff() { [[ $1 == true ]] && echo 开启 || echo 关闭; }

vw_version() {
  timeout 10 docker exec "$VW_CONTAINER" /vaultwarden --version 2>/dev/null | awk '{ print $NF }' ||
    docker inspect -f '{{.Config.Image}}' "$VW_CONTAINER" 2>/dev/null
}

show_status() {
  need_instance
  title "Vaultwarden 状态"
  local health
  health=$(docker inspect -f '{{.State.Status}}{{if .State.Health}} / {{.State.Health.Status}}{{end}}' "$VW_CONTAINER" 2>/dev/null)
  printf '  %-16s %s\n' "容器" "$VW_CONTAINER（$health）"
  printf '  %-16s %s\n' "数据目录" "$VW_DATA_DIR"
  printf '  %-16s %s\n' "版本" "$(vw_version)"
  printf '  %-16s %s\n' "DOMAIN" "$(vw_eff domain DOMAIN 未设置)"
  printf '  %-16s %s（来源：%s）\n' "开放注册" "$(onoff "$(vw_eff signups_allowed SIGNUPS_ALLOWED true)")" "$(vw_src signups_allowed SIGNUPS_ALLOWED)"
  printf '  %-16s %s（来源：%s）\n' "邀请注册" "$(onoff "$(vw_eff invitations_allowed INVITATIONS_ALLOWED true)")" "$(vw_src invitations_allowed INVITATIONS_ALLOWED)"
  local adm
  case $(vw_admin_state) in
    off) adm="关闭" ;;
    argon2) adm="开启（argon2 哈希令牌）" ;;
    plain) adm="开启（明文令牌，建议更换为哈希）" ;;
    notoken) adm="开启且免令牌（危险）" ;;
  esac
  printf '  %-16s %s（来源：%s）\n' "后台 /admin" "$adm" "$(vw_src admin_token ADMIN_TOKEN)"
  echo
  echo "  安全选项："
  printf '    %-24s %s\n' "密码提示" "$(onoff "$(vw_eff password_hints_allowed PASSWORD_HINTS_ALLOWED true)")"
  printf '    %-24s %s\n' "登录页直接显示密码提示" "$(onoff "$(vw_eff show_password_hint SHOW_PASSWORD_HINT false)")"
  printf '    %-24s %s\n' "Send" "$(onoff "$(vw_eff sends_allowed SENDS_ALLOWED true)")"
  printf '    %-24s %s\n' "紧急访问" "$(onoff "$(vw_eff emergency_access_allowed EMERGENCY_ACCESS_ALLOWED true)")"
  local org
  org=$(vw_eff org_creation_users ORG_CREATION_USERS "")
  printf '    %-24s %s\n' "可创建组织的用户" "${org:-所有人}"
  printf '    %-24s %s\n' "图标服务" "$(vw_eff icon_service ICON_SERVICE internal)"
  if [[ -n $(vw_env SIGNUPS_ALLOWED)$(vw_env ADMIN_TOKEN) ]] && [[ -f $VW_DATA_DIR/config.json ]]; then
    echo
    log_info "config.json 中的设置优先于 1Panel 应用参数；以上为实际生效值"
  fi
}

toggle_signups() {
  need_instance
  local cur want
  cur=$(vw_eff signups_allowed SIGNUPS_ALLOWED true)
  title "开放注册"
  echo "当前：$(onoff "$cur")（来源：$(vw_src signups_allowed SIGNUPS_ALLOWED)）"
  echo "邀请注册：$(onoff "$(vw_eff invitations_allowed INVITATIONS_ALLOWED true)")（组织管理员可邀请新用户，与开放注册无关）"
  echo
  echo "  [1] 开启开放注册   [2] 关闭开放注册"
  echo "  [3] 开启邀请注册   [4] 关闭邀请注册   [0] 返回"
  local c key desc
  read -r -p "请选择：" c || return 0
  case $c in
    1) key=signups_allowed want=true desc="开启开放注册" ;;
    2) key=signups_allowed want=false desc="关闭开放注册" ;;
    3) key=invitations_allowed want=true desc="开启邀请注册" ;;
    4) key=invitations_allowed want=false desc="关闭邀请注册" ;;
    *) return 0 ;;
  esac
  [[ $key == signups_allowed && $want == true ]] &&
    log_warn "开启后任何能访问域名的人都可以注册账号。建议注册完自己的账号后立即关闭"
  confirm_yes "$desc？修改前会调用 vbm 备份，之后重启 Vaultwarden" || return 0
  vw_apply "$desc" "$(printf '%s\t%s' "$key" "$want")"
}

# ---------- 后台 ADMIN ----------
argon2_hash() { # 从标准输入读取密码，输出 PHC 格式 argon2id 哈希（参数与 vaultwarden hash 的 OWASP 预设一致）
  local salt
  salt=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
  argon2 "$salt" -e -id -k 19456 -t 2 -p 1
}

ensure_argon2() {
  command -v argon2 >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || { log_err "需要 argon2 命令，请手动安装"; return 1; }
  confirm_yes "生成哈希需要安装 argon2 软件包，现在安装？" || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y argon2 >/dev/null || { log_err "安装 argon2 失败"; return 1; }
}

set_admin_token() {
  ensure_argon2 || return 1
  local mode pw pw2 hash
  echo "  [1] 自动生成随机密码（推荐）   [2] 自己输入密码"
  read -r -p "请选择 [1]：" mode || return 0
  if [[ ${mode:-1} == 2 ]]; then
    read -r -s -p "输入后台密码（至少 12 位）：" pw || return 0
    echo
    read -r -s -p "再输入一次：" pw2 || return 0
    echo
    [[ $pw == "$pw2" ]] || { log_err "两次输入不一致"; return 1; }
    ((${#pw} >= 12)) || { log_err "密码太短"; return 1; }
  else
    pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n' | head -c 28)
  fi
  hash=$(printf '%s' "$pw" | argon2_hash) || { log_err "生成哈希失败"; return 1; }
  [[ $hash == '$argon2id$'* ]] || { log_err "生成哈希失败"; return 1; }
  if [[ ${mode:-1} != 2 ]]; then
    echo
    printf '%s后台密码（只显示这一次，请立即保存到密码管理器）：%s\n\n    %s\n\n' "$C_Y" "$C_0" "$pw"
    read -r -p "已保存？按 Enter 继续 " _ || true
  fi
  unset pw pw2
  log_info "config.json 中只保存 argon2 哈希，不保存密码本身"
  confirm_yes "开启后台并设置该密码？修改前会调用 vbm 备份，之后重启 Vaultwarden" || return 0
  vw_apply "设置后台 ADMIN 令牌（argon2）" "$(printf 'admin_token\t"%s"\ndisable_admin_token\tfalse' "$hash")"
}

disable_admin() {
  log_info "关闭后 /admin 页面不可访问；以后需要时可在这里重新开启"
  confirm_yes "关闭后台 /admin？修改前会调用 vbm 备份，之后重启 Vaultwarden" || return 0
  # 空字符串会覆盖 1Panel 应用参数中的 ADMIN_TOKEN，使后台保持关闭
  vw_apply "关闭后台 ADMIN" "$(printf 'admin_token\t""\ndisable_admin_token\tfalse')"
}

admin_menu() {
  need_instance
  title "后台 ADMIN"
  local st
  st=$(vw_admin_state)
  case $st in
    off) echo "当前：关闭" ;;
    argon2) echo "当前：开启（argon2 哈希令牌）" ;;
    plain) log_warn "当前：开启，但令牌是明文保存的，建议更换为哈希" ;;
    notoken) log_warn "当前：开启且免令牌，任何人都能进入后台！" ;;
  esac
  local domain
  domain=$(vw_eff domain DOMAIN "")
  [[ -n $domain ]] && echo "后台地址：${domain%/}/admin"
  echo
  echo "  [1] 开启后台 / 更换密码"
  echo "  [2] 关闭后台"
  echo "  [0] 返回"
  local c
  read -r -p "请选择：" c || return 0
  case $c in
    1) set_admin_token ;;
    2) disable_admin ;;
  esac
  echo
  echo "建议：在 1Panel 网站的反向代理中只允许你的 IP 访问 /admin，不用时关闭后台。"
}

# ---------- 用户列表 ----------
list_users() {
  need_instance
  title "用户列表（只读）"
  local db=$VW_DATA_DIR/db.sqlite3 url
  url=$(vw_env DATABASE_URL)
  if [[ -n $url && $url != *sqlite* && $url != /* && $url != data/* ]]; then
    log_warn "该实例使用外部数据库（非 SQLite），暂不支持列出用户"
    return 0
  fi
  [[ -f $db ]] || { log_err "找不到数据库 $db"; return 1; }
  python3 - "$db" <<'PY'
import sqlite3, sys
try:
    con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=5)
except sqlite3.Error as exc:
    sys.exit(f"[错误] 无法只读打开数据库：{exc}")
cols = {r[1] for r in con.execute("PRAGMA table_info(users)")}
tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
enabled = "u.enabled" if "enabled" in cols else "1"
# atype 100 为「记住此设备」，>= 1000 为尚未完成的设置，均不算已开启两步验证
tfa = ("(SELECT COUNT(*) FROM twofactor t WHERE t.user_uuid = u.uuid AND t.enabled AND t.atype < 1000 AND t.atype != 100)"
       if "twofactor" in tables else "0")
last = "(SELECT MAX(d.updated_at) FROM devices d WHERE d.user_uuid = u.uuid)" if "devices" in tables else "NULL"
rows = con.execute(f"SELECT u.email, u.created_at, {last}, {tfa}, {enabled} FROM users u ORDER BY u.created_at").fetchall()
if not rows:
    print("  没有用户")
    sys.exit(0)
print(f"  {'邮箱':<34}{'注册时间':<22}{'最近活动':<22}{'两步验证':<10}状态")
for email, created, seen, n2fa, en in rows:
    print(f"  {email:<36}{(created or '-')[:19]:<26}{(seen or '-')[:19]:<26}{'已开启' if n2fa else '未开启':<10}{'正常' if en else '已禁用'}")
print(f"\n  共 {len(rows)} 个用户。时间为 UTC。")
PY
  echo
  echo "不认识的账号请到后台 /admin →「Users」中禁用或删除（vhm 不修改数据库）。"
}

# ---------- 安全选项 ----------
options_menu() {
  need_instance
  title "安全选项"
  local hints show sends emerg org icon
  hints=$(vw_eff password_hints_allowed PASSWORD_HINTS_ALLOWED true)
  show=$(vw_eff show_password_hint SHOW_PASSWORD_HINT false)
  sends=$(vw_eff sends_allowed SENDS_ALLOWED true)
  emerg=$(vw_eff emergency_access_allowed EMERGENCY_ACCESS_ALLOWED true)
  org=$(vw_eff org_creation_users ORG_CREATION_USERS "")
  icon=$(vw_eff icon_service ICON_SERVICE internal)
  printf '  [1] 密码提示                 %s（建议关闭：提示常常就是密码本身）\n' "$(onoff "$hints")"
  printf '  [2] 登录页直接显示密码提示   %s（建议关闭：未配置邮件时会把提示直接显示给任何人）\n' "$(onoff "$show")"
  printf '  [3] Send                     %s（不用分享功能可关闭）\n' "$(onoff "$sends")"
  printf '  [4] 紧急访问                 %s（不用可关闭）\n' "$(onoff "$emerg")"
  printf '  [5] 可创建组织的用户         %s\n' "${org:-所有人}"
  printf '  [6] 图标服务                 %s（建议 internal：外部服务会获知你保存了哪些网站）\n' "$icon"
  echo "  [7] 一键推荐设置（关闭 1、2、4，组织仅允许指定邮箱，图标服务 internal；Send 保持不变）"
  echo "  [0] 返回"
  local c upd="" desc
  read -r -p "请选择：" c || return 0
  case $c in
    1) upd=$(printf 'password_hints_allowed\t%s' "$([[ $hints == true ]] && echo false || echo true)") desc="密码提示：$(onoff "$([[ $hints == true ]] && echo false || echo true)")" ;;
    2) upd=$(printf 'show_password_hint\t%s' "$([[ $show == true ]] && echo false || echo true)") desc="显示密码提示：$(onoff "$([[ $show == true ]] && echo false || echo true)")" ;;
    3) upd=$(printf 'sends_allowed\t%s' "$([[ $sends == true ]] && echo false || echo true)") desc="Send：$(onoff "$([[ $sends == true ]] && echo false || echo true)")" ;;
    4) upd=$(printf 'emergency_access_allowed\t%s' "$([[ $emerg == true ]] && echo false || echo true)") desc="紧急访问：$(onoff "$([[ $emerg == true ]] && echo false || echo true)")" ;;
    5 | 7)
      local who
      echo "可创建组织的用户：all = 所有人，none = 禁止所有人，或填写邮箱（多个用英文逗号分隔）"
      who=$(read_default "设置为" "${org:-all}")
      [[ $who =~ ^[A-Za-z0-9._%+@,-]+$ ]] || { log_err "格式无效"; return 1; }
      [[ $who == all ]] && who=""
      if [[ $c == 5 ]]; then
        upd=$(printf 'org_creation_users\t"%s"' "$who") desc="可创建组织的用户：${who:-所有人}"
      else
        upd=$(printf 'password_hints_allowed\tfalse\nshow_password_hint\tfalse\nemergency_access_allowed\tfalse\norg_creation_users\t"%s"\nicon_service\t"internal"' "$who")
        desc="Vaultwarden 推荐安全选项"
      fi
      ;;
    6)
      local svc
      svc=$(read_default "图标服务（internal / bitwarden / duckduckgo / google）" internal)
      [[ $svc =~ ^(internal|bitwarden|duckduckgo|google)$ ]] || { log_err "不支持的图标服务"; return 1; }
      upd=$(printf 'icon_service\t"%s"' "$svc") desc="图标服务：$svc"
      ;;
    *) return 0 ;;
  esac
  confirm_yes "应用「$desc」？修改前会调用 vbm 备份，之后重启 Vaultwarden" || return 0
  vw_apply "$desc" "$upd"
}

case ${1:-status} in
  status) show_status ;;
  signups) need_root; with_lock toggle_signups ;;
  admin) need_root; with_lock admin_menu ;;
  users) list_users ;;
  options) need_root; with_lock options_menu ;;
  *) die "未知参数：$1" ;;
esac
