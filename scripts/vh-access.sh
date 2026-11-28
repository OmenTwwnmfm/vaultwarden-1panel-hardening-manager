#!/usr/bin/env bash
# 按用户配置 SSH；可创建普通账户。三项验证和 sudo 迁移只接受已有管理员。
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-ssh.sh
source "$VH_DIR/vh-ssh.sh"

ACCESS_PASSWD_FILE=${ACCESS_PASSWD_FILE:-/etc/passwd}
ACCESS_SHELLS_FILE=${ACCESS_SHELLS_FILE:-/etc/shells}

access_user_name_ok() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]]; }
access_login_shell_ok() {
  [[ $1 == /* && -x $1 && $1 != */nologin && $1 != */false ]] && grep -Fxq -- "$1" "$ACCESS_SHELLS_FILE"
}

access_set_user() { # 仅本地和 NSS 都确认不存在时返回 2
  local user=$1 entry resolved rc uid gid home shell
  access_user_name_ok "$user" || { log_err '用户名须以小写字母或下划线开头，最多 32 个小写字母、数字、下划线或短横线；root 请单独选择'; return 1; }
  entry=$(awk -F: -v u="$user" '$1 == u { print }' "$ACCESS_PASSWD_FILE") || { log_err '无法读取本地账户文件'; return 1; }
  if resolved=$(getent passwd "$user"); then
    [[ -n $entry && $entry == "$resolved" && $entry != *$'\n'* ]] || { log_err "$user 不是唯一可确认的本地账号"; return 1; }
  else
    rc=$?
    if ((rc == 2)) && [[ -z $entry ]]; then log_warn "未找到用户 $user"; return 2; fi
    log_err "无法通过系统账户数据库确认 $user"
    return 1
  fi
  IFS=: read -r _ _ uid gid _ home shell <<<"$entry"
  [[ $uid =~ ^[1-9][0-9]{3,4}$ && $gid =~ ^[0-9]+$ && $uid -lt 65534 && $home == /* ]] || { log_err "请选择 UID 1000–65533 的普通用户"; return 1; }
  awk -F: -v uid="$uid" '$3 == uid { n++ } END { exit n != 1 }' "$ACCESS_PASSWD_FILE" || { log_err '该 UID 对应多个账户，请先人工整理'; return 1; }
  access_login_shell_ok "$shell" || { log_err "$user 没有可用的交互 shell"; return 1; }
  ACCESS_USER=$user ACCESS_UID=$uid
  ACCESS_KEY_FILE="$ACCESS_KEYS_DIR/$user"
  ACCESS_GA_FILE="$ACCESS_SECRETS_DIR/$user/totp"
}

# 所有配置与秘密均放在 root 控制的路径；拒绝符号链接和可被其他用户替换的路径。
access_safe_path() {
  local path=$1 owner mode
  [[ $path == /* && $path != *[$' \t\r\n']* ]] || { log_err "不支持的配置路径：$path"; return 1; }
  while [[ $path != / ]]; do
    [[ ! -L $path ]] || { log_err "拒绝符号链接：$path"; return 1; }
    if [[ -e $path ]]; then
      owner=$(stat -c %u -- "$path") && mode=$(stat -c %a -- "$path") || return 1
      [[ $owner == 0 ]] && (((8#$mode & 8#022) == 0)) || { log_err "路径必须由 root 所有且不可被他人写入：$path"; return 1; }
    fi
    path=$(dirname -- "$path")
  done
}

access_write() { # access_write 文件 权限；从 stdin 读取，在同目录原子替换
  local path=$1 mode=$2 tmp
  tmp=$(mktemp "$(dirname "$path")/.vhm-access.XXXXXX") || return 1
  if cat >"$tmp" && chown root:root "$tmp" && chmod "$mode" "$tmp" && mv -fT -- "$tmp" "$path"; then return 0; fi
  rm -f -- "$tmp"
  return 1
}

access_ssh_preflight() {
  local user=$1 eff
  eff=$(sshd_eff_for "$user") || { log_err "不能按普通用户读取真实 sshd -T 配置"; return 1; }
  grep -Fxq 'usepam yes' <<<"$eff" || { log_err "此向导要求现有 SSH 已启用 UsePAM yes；请先在 [06] 配置现有登录方式"; return 1; }
  access_profile_preflight "$user" key_password_totp
}

access_ssh_apply() {
  access_profile_apply "$1" key_password_totp "$ACCESS_KEY_FILE" "$ACCESS_GA_FILE"
}

access_expect_for() { # access_expect_for 用户 来源地址 配置项 期望值
  local eff actual
  eff=$(sshd_eff_for "$1" "$2") || { log_err "sshd 无法计算 $1 的生效配置"; return 1; }
  actual=$(awk -v key="$3" '$1 == key { $1=""; sub(/^ /, ""); print }' <<<"$eff")
  if [[ $3 == permitrootlogin && $actual == without-password ]]; then actual=prohibit-password; fi
  [[ $actual == "$4" ]] || { log_err "$1 的 $3 为 ${actual:-空}，期望 $4"; return 1; }
}

access_ssh_expect() {
  access_profile_expect "$1" key_password_totp "$ACCESS_KEY_FILE"
}

access_disable_root() {
  local user=$1
  access_profile_disable_root "$user" && access_ssh_expect "$user" && access_root_ssh_closed
}

access_root_ssh_closed() {
  local addr connection_text=${SSH_CONNECTION:-}
  for addr in "${connection_text%% *}" 203.0.113.1 2001:db8::1; do
    [[ -n $addr ]] || continue
    access_expect_for root "$addr" permitrootlogin no || return 1
  done
}

access_track() {
  local path
  for path in "$SSHD_CONFIG" "$PAM_SSHD" "$PAM_ACCESS_SSH" "$PAM_ACCESS_LEGACY" \
    "$ACCESS_KEY_FILE" "$ACCESS_GA_FILE" "$ACCESS_STATE"; do
    change_track "$path" || return 1
  done
  access_profile_track "$ACCESS_USER" && access_sudo_track
}

access_context() {
  if [[ $1 == root ]]; then
    ACCESS_USER=root ACCESS_UID=0
    ACCESS_KEY_FILE="$ACCESS_KEYS_DIR/root" ACCESS_GA_FILE="$ACCESS_SECRETS_DIR/root/totp"
  else
    access_set_user "$1"
  fi
}

access_list_users() {
  local user uid home shell users=()
  [[ -r $ACCESS_PASSWD_FILE && -r $ACCESS_SHELLS_FILE ]] || return 0
  while IFS=: read -r user _ uid _ _ home shell; do
    access_user_name_ok "$user" && [[ $uid =~ ^[1-9][0-9]{3,4}$ && $uid -lt 65534 && $home == /* ]] &&
      access_login_shell_ok "$shell" && users+=("$user")
  done <"$ACCESS_PASSWD_FILE"
  if ((${#users[@]})); then printf '  本机普通用户：%s\n' "${users[*]}"; else echo '  当前没有可选的本机普通用户'; fi
}

access_password_terminal() { [[ -t 0 ]]; }

access_has_password() {
  local status
  status=$(LC_ALL=C passwd -S "$1" 2>/dev/null) || return 1
  [[ $(awk '{print $1, $2}' <<<"$status") == "$1 P" ]]
}

access_create_user() { # 仅 [06] 在确认用户名不存在后调用
  local user=$1 home="/home/$1" tool gid group_name groups sudo_status=0
  access_user_name_ok "$user" || return 1
  for tool in useradd passwd id; do
    command -v "$tool" >/dev/null 2>&1 || { log_err "缺少 $tool，无法创建用户"; return 1; }
  done
  if [[ -e $home || -L $home ]]; then
    log_err "$home 已存在，请换一个用户名或在系统中人工核对后创建"
    return 1
  fi
  access_safe_path "$home" && access_login_shell_ok /bin/bash || { log_err '用户主目录路径或 /bin/bash 不符合创建要求'; return 1; }
  VH_ASSUME_YES=0 confirm_yes "创建本地普通用户 $user 并设置密码？不会授予 sudo；单独配置前，该账号沿用现有默认 SSH 规则。" || return 1
  access_password_terminal || { log_err '创建用户需要交互终端，以便通过系统 passwd 安全设置密码'; return 1; }
  if ! useradd --create-home --home-dir "$home" --user-group --shell /bin/bash -- "$user"; then
    log_err "系统未确认创建 $user 成功；请运行 getent passwd $user 检查。向导未设置密码或更改 SSH 配置。"
    return 1
  fi
  if ! { access_set_user "$user" && gid=$(id -g "$user") && group_name=$(id -gn "$user") && groups=$(id -G "$user") &&
    [[ $gid =~ ^[1-9][0-9]*$ && $group_name == "$user" && $groups == "$gid" ]]; }; then
    log_err "$user 已创建，但未通过普通账号或独立用户组校验。请人工核对；向导未设置密码或更改 SSH 配置。"
    return 1
  fi
  if command -v sudo >/dev/null 2>&1; then
    access_sudo_list_rules "$user" || sudo_status=$?
    case $sudo_status in
      0) log_err "$user 已创建，但现有 sudo 规则允许该用户使用 sudo。请先人工核对授权；向导未设置密码或更改 SSH 配置。"; return 1 ;;
      1) ;;
      *) log_err "$user 已创建，但无法核对现有 sudo 权限。请先人工核对授权；向导未设置密码或更改 SSH 配置。"; return 1 ;;
    esac
  fi
  log_info "请按系统提示为 $user 设置密码。"
  if ! passwd "$user" || ! access_has_password "$user"; then
    log_warn "$user 已创建，但未确认可用密码。请先运行 passwd $user 或在 [06] 选该用户后用 [5] 设置密码；SSH 配置未改动。"
    return 1
  fi
  log_ok "已创建普通用户 $user。请选择该用户的 SSH 登录方式。"
}

access_choose_user() {
  local action=${1:-select} choice user rc
  echo '  [1] root    [2] 普通用户    [0] 返回' >&2
  read -r -p '选择要配置的用户类型: ' choice || return 1
  case $choice in
    1) printf 'root\n' ;;
    2)
      access_list_users >&2
      if [[ $action == create ]]; then
        read -r -p '普通用户名（不存在时可选择创建，回车返回）: ' user || return 1
      else
        read -r -p '已有普通用户名（回车返回）: ' user || return 1
      fi
      [[ -n $user ]] || return 1
      rc=0
      access_set_user "$user" >&2 || rc=$?
      case $rc in
        0) ;;
        2) [[ $action == create ]] || { log_warn '此处只选择已有用户；可到 [06] 创建普通用户。' >&2; return 1; }
           access_create_user "$user" >&2 || return 1 ;;
        *) return 1 ;;
      esac
      printf '%s\n' "$user"
      ;;
    0 | '') return 1 ;;
    *) log_warn '请选择 1、2 或 0' >&2; return 1 ;;
  esac
}

access_read_public_key() {
  local line
  echo "粘贴 $1 的一行 SSH 公钥（不读取私钥）："
  read -r line || return 1
  [[ $line =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[^[:space:]]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]] ]] || {
    log_err '公钥格式不支持'; return 1;
  }
  printf '%s\n' "$line" >"$2" && ssh-keygen -lf "$2" || { log_err '公钥校验失败'; return 1; }
}

access_profile_configure() (
  local user=$1 mode=$2 path eff temp_dir newga="" keytmp="" permit=""
  access_context "$user" || return 1
  if access_active && { [[ $user == root ]] || [[ $user == "$(access_user)" ]]; }; then
    log_err '该账户属于已启用的普通管理员安全方案，请先在 [25] 回滚原迁移，再更换登录方式。'
    return 1
  fi
  eff=$(sshd_eff_for "$user") || { log_err '无法按所选用户读取 sshd 生效配置'; return 1; }
  grep -Fxq 'usepam yes' <<<"$eff" || { log_err '分用户配置要求现有 UsePAM yes；请先人工检查并启用系统 PAM，再运行向导'; return 1; }
  if [[ $mode == *_totp ]]; then ga_install || return 1; fi
  access_profile_preflight "$user" "$mode" || return 1
  if [[ $mode == password* ]]; then
    access_has_password "$user" || { log_err "$user 尚无可用账户密码，请先设置密码"; return 1; }
  fi
  temp_dir=$(mktemp -d) || return 1
  trap 'rm -rf -- "$temp_dir"' EXIT
  if [[ $mode == key* && ! -s $ACCESS_KEY_FILE ]]; then
    keytmp="$temp_dir/authorized_keys"
    access_read_public_key "$user" "$keytmp" || return 1
  fi
  if [[ $mode == *_totp ]]; then
    time_synced || { log_err '先确认系统时间已同步，再启用 TOTP'; return 1; }
    if [[ ! -f $ACCESS_GA_FILE ]]; then
      local GA_FILE="$temp_dir/totp" GA_ACCOUNT="$user"
      newga=$(ga_bind_new) || return 1
    fi
  fi
  for path in "$ACCESS_KEY_FILE" "$ACCESS_GA_FILE"; do access_safe_path "$path" || return 1; done
  echo "只更改 $user 的 SSH 登录方式为：$(auth_mode_label "$mode")。其他用户保留各自配置。"
  if [[ $user == root ]]; then
    if [[ $(access_root_policy 2>/dev/null) == no ]]; then
      log_err 'vhm 已关闭 root SSH，恢复请在 [25] 回滚该记录。'
      return 1
    fi
    permit=yes
    [[ $mode != key ]] || permit=prohibit-password
    echo '此选项会允许 root 按所选方式通过 SSH 登录。'
  fi
  confirm_yes '已打开 VNC 应急控制台，继续？' || return 0
  change_begin "$user 的 SSH 登录方式：$(auth_mode_label "$mode")" sshd
  if ! { access_profile_track "$user" &&
    { [[ -z $keytmp ]] || change_track "$ACCESS_KEY_FILE"; } &&
    { [[ -z $newga ]] || change_track "$ACCESS_GA_FILE"; }; }; then
    change_status rolled_back
    log_err '未能完整备份配置，未修改登录方式'
    return 1
  fi
  guard_start || return 1
  if ! { install -d -o root -g root -m 755 "$ACCESS_KEYS_DIR" &&
    install -d -o root -g root -m 700 "$ACCESS_SECRETS_DIR" "$ACCESS_SECRETS_DIR/$user" &&
    { [[ -z $keytmp ]] || install -o root -g root -m 644 "$keytmp" "$ACCESS_KEY_FILE"; } &&
    { [[ -z $newga ]] || install -o root -g root -m 600 "$newga" "$ACCESS_GA_FILE"; } &&
    access_profile_apply "$user" "$mode" "$ACCESS_KEY_FILE" "$ACCESS_GA_FILE" "$permit"; }; then
    guard_abort
    return 1
  fi
  if [[ $user == root ]]; then
    access_expect_for root 203.0.113.1 permitrootlogin "$permit" || { guard_abort; return 1; }
  fi
  access_profile_expect "$user" "$mode" "$ACCESS_KEY_FILE" &&
    test_ssh_change "ssh -o ControlMaster=no -o ControlPath=none -p $(cur_ports | head -n1) $user@$(server_ip)" &&
    guard_confirm || { guard_abort; return 1; }
  log_ok "$user 的 SSH 登录方式已更新：$(auth_mode_label "$mode")"
)

access_auth_menu() {
  local user choice
  title 'SSH 登录方式：按用户配置'
  user=$(access_choose_user create) || return 0
  title "$user 的 SSH 登录方式"
  echo "已单独配置：$(access_profile_get "$user" 2>/dev/null || echo '沿用原 SSH 配置')"
  echo '  [1] 密码登录（不建议）'
  echo '  [2] 密钥登录'
  echo '  [3] 密码 + 2FA（TOTP）'
  echo '  [4] 密钥 + 2FA（TOTP）'
  echo "  [5] 修改 $user 的系统密码"
  if [[ $user != root ]]; then
    echo '  [6] 普通管理员（须已有 sudo 权限）：密钥 + 密码 + TOTP；sudo 每次密码 + TOTP；验证后禁 root SSH'
    echo "  [7] 授予 $user sudo 管理权限（需确认）"
    echo '  [8] 验证此用户的 SSH 和 sudo，再关闭 root SSH'
  fi
  echo '  [0] 返回'
  read -r -p '请选择：' choice || return 0
  case $choice in
    1) access_profile_configure "$user" password ;;
    2) access_profile_configure "$user" key ;;
    3) access_profile_configure "$user" password_totp ;;
    4) access_profile_configure "$user" key_totp ;;
    5) confirm_yes "通过 passwd 修改 $user 的账户密码？不保存密码，不能回滚。" && passwd "$user" ;;
    6) [[ $user == root ]] || access_setup "$user" ;;
    7) [[ $user == root ]] || access_grant_sudo "$user" ;;
    8) [[ $user == root ]] || access_disable_root_menu "$user" ;;
  esac
}

access_profile_tfa_menu() (
  local user mode choice codes temp_dir newga
  user=$(access_choose_user) || return 0
  if access_active && [[ $user == "$(access_user)" ]]; then access_tfa_manage; return; fi
  access_context "$user" || return 1
  if ! mode=$(access_profile_get "$user"); then
    if [[ $user == root ]]; then tfa_legacy_manage; else log_warn '此用户尚未独立配置，请先通过 [06] 选择登录方式'; fi
    return 0
  fi
  [[ $mode == *_totp ]] || { log_info '此用户的 SSH 登录方式没有启用 TOTP'; return 0; }
  local GA_FILE="$ACCESS_GA_FILE" GA_ACCOUNT="$user"
  title "$user 的 SSH 动态口令"
  echo '  [1] 显示绑定二维码    [2] 重新绑定    [3] 查看应急码    [4] 关闭 2FA（改为密钥登录）    [0] 返回'
  read -r -p '请选择：' choice || return 0
  case $choice in
    1) confirm_yes '二维码等同动态口令密钥，确认显示？' && ga_show_qr "$GA_FILE" ;;
    2)
      temp_dir=$(mktemp -d) || return 1
      trap 'rm -rf -- "$temp_dir"' EXIT
      local GA_FILE="$temp_dir/totp"
      newga=$(ga_bind_new) || return 1
      confirm_yes "替换 $user 的动态口令绑定？" || return 0
      change_begin "重新绑定 $user 的 SSH 动态口令"
      change_track "$ACCESS_GA_FILE" && guard_start || return 1
      install -o root -g root -m 600 "$newga" "$ACCESS_GA_FILE" &&
        guard_wait_confirm "ssh -p $(cur_ports | head -n1) $user@$(server_ip)" && guard_confirm || { guard_abort; return 1; }
      ;;
    3)
      confirm_yes '显示一次性应急码？' || return 0
      codes=$(grep -E '^[0-9]{8}$' "$ACCESS_GA_FILE" || true)
      if [[ -n $codes ]]; then printf '%s\n' "$codes"; else log_warn '应急码已用完，请重新绑定'; fi
      ;;
    4) access_profile_configure "$user" key ;;
  esac
)

access_session() { _ssh_login_identity "$1" "$2"; }

access_ticks() { python3 -c 'import os; print(int(float(open("/proc/uptime").read().split()[0]) * os.sysconf("SC_CLK_TCK")))'; }

access_verify() {
  local id=${1:-} phase=${2:-} dir user session cutoff kind=strong
  need_root
  [[ $id =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ && $phase =~ ^(login|final)$ ]] || { log_err "无效的迁移验证参数"; return 1; }
  dir="$VH_CHANGES/$id"
  [[ -f $dir/access-user && -f $dir/access-phase && $(cat "$dir/status" 2>/dev/null) == pending && $(cat "$dir/access-phase") == "$phase" ]] || { log_err "此迁移阶段已结束或尚未开始"; return 1; }
  user=$(cat "$dir/access-user")
  access_set_user "$user" || return 1
  [[ ${SUDO_USER:-} == "$user" && ${SUDO_UID:-} == "$ACCESS_UID" ]] || { log_err "必须在新 SSH 会话中由 $user 直接执行所示 sudo 命令"; return 1; }
  [[ ${SUDO_COMMAND:-} == "/usr/local/bin/vhm access-verify $id $phase" ]] || { log_err '请直接执行向导给出的 sudo vhm access-verify 命令，不要从已打开的 root shell 验证'; return 1; }
  session=$(access_session "$user" "$ACCESS_UID") || { log_err "无法确认来自该用户的新 SSH 会话，请勿从 root shell 或复用连接执行"; return 1; }
  cutoff=$(cat "$dir/access-cutoff") || return 1
  [[ $cutoff =~ ^[0-9]+$ && ${session##*:} -gt $cutoff ]] || { log_err "请关闭连接复用，建立本阶段开始后的新 SSH 连接"; return 1; }
  if [[ -f $dir/access-kind ]]; then kind=$(cat "$dir/access-kind") || return 1; fi
  case $kind in
    strong)
      access_profile_verify "$user" key_password_totp "$ACCESS_KEY_FILE" "$ACCESS_GA_FILE" &&
        access_ssh_expect "$user" && access_sudo_verify "$user" "$ACCESS_GA_FILE" || return 1
      ;;
    root-ssh) access_sudo_can_manage "$user" || return 1 ;;
    *) return 1 ;;
  esac
  [[ $phase != final ]] || access_root_ssh_closed || return 1
  (
    exec 7>"$dir/.lock" && flock -w 5 7 || exit 1
    [[ $(cat "$dir/status") == pending && $(cat "$dir/access-phase") == "$phase" && $(cat "$dir/access-cutoff") == "$cutoff" ]] || exit 1
    printf '%s\n' "$session" | access_write "$dir/access-verified-$phase" 600
  ) || { log_err '迁移阶段已结束，请回到原窗口。'; return 1; }
  log_ok "普通用户的新 SSH 会话和 sudo 调用已验证，请回到原窗口继续"
}

access_wait_verify() {
  local phase=$1 kind=${2:-strong} ans user=$ACCESS_USER port remaining
  [[ -n ${ACCESS_DEADLINE:-} ]] || ACCESS_DEADLINE=$((SECONDS + GUARD_SECONDS))
  remaining=$((ACCESS_DEADLINE - SECONDS))
  ((remaining > 0)) || { log_err '迁移保护时间已到，正在回滚'; return 1; }
  port=$(cur_ports | head -n1)
  printf '%s\n' "$user" >"$CHG_DIR/access-user" &&
    access_ticks >"$CHG_DIR/access-cutoff" &&
    printf '%s\n' "$phase" | access_write "$CHG_DIR/access-phase" 600 || return 1
  echo
  echo "保持本窗口；另开一个新的 SSH 连接（禁用连接复用）："
  echo "  ssh -o ControlMaster=no -o ControlPath=none -p $port $user@$(server_ip)"
  if [[ $kind == root-ssh ]]; then
    echo '按该账户现有的 SSH 和 sudo 规则完成验证，然后回到本窗口。'
    echo "  sudo -k /usr/local/bin/vhm access-verify $CHG_ID $phase"
    echo '请直接运行上面的 sudo 命令，不要先进入 root shell。'
  else
    echo "依次通过公钥、账户密码和动态验证码，然后直接执行："
    echo "  sudo /usr/local/bin/vhm access-verify $CHG_ID $phase"
    echo "sudo 必须再次要求账户密码和动态验证码；验证码已用于登录时，请等下一组。"
    echo "不要进入 sudo -i / su；确认每项都被要求后回到这里。"
  fi
  echo "本次迁移的保护时间共 $GUARD_SECONDS 秒，当前剩余 $remaining 秒。"
  read -r -t "$remaining" -p "新窗口验证完成后输入 yes（其他输入回滚）: " ans || ans=""
  if [[ ${ans,,} != yes || ! -s $CHG_DIR/access-verified-$phase || $(cat "$CHG_DIR/status") != pending ]] || ((SECONDS >= ACCESS_DEADLINE)); then
    log_err "新会话验证未完成，正在回滚"
    return 1
  fi
}

access_sudo_can_manage() {
  if ! command -v sudo >/dev/null 2>&1 || ! LC_ALL=C sudo -n -l -U "$1" -u root -- /bin/sh >/dev/null 2>&1; then
    log_err "$1 没有可确认的 root 管理权限。请先通过 [7] 授权，或由管理员核对现有 sudo 规则。"
    return 1
  fi
}

access_record_admin_dependency() { # 告诉 [25] 此变更依赖已由 vhm 授予的 sudo 权限，不修改该文件
  local grant="$SUDOERS_DIR/90-vhm-admin-$1"
  [[ ! -f $grant ]] || printf '%s\n' "$grant" >"$CHG_DIR/admin-required"
}

access_root_cutover() (
  # 与自动回滚共用记录锁，避免保护到期时仍在写入配置。
  exec 7>"$CHG_DIR/.lock" && flock -w 5 7 || return 1
  [[ $(cat "$CHG_DIR/status") == pending ]] && ((SECONDS < ACCESS_DEADLINE)) || return 1
  access_root_apply && access_root_ssh_closed && ssh_reload
)

access_disable_root_menu() (
  local user=$1
  access_set_user "$user" && access_root_preflight || return 1
  if access_root_ssh_closed >/dev/null 2>&1; then
    log_info 'root SSH 已关闭。通过 vhm 关闭的记录可在 [25] 回滚。'
    return 0
  fi
  access_sudo_can_manage "$user" || return 1
  VH_ASSUME_YES=0 confirm_yes "已打开 VPS 控制台并保留当前窗口，验证 $user 后关闭 root SSH？root 账号及现有 sudo 规则保留。" || return 0
  change_begin "验证普通管理员 $user 后关闭 root SSH" sshd
  if ! access_root_track || ! access_record_admin_dependency "$user" || ! printf 'root-ssh\n' >"$CHG_DIR/access-kind"; then
    change_status rolled_back
    log_err '无法保存完整记录，未更改 SSH。'
    return 1
  fi
  ACCESS_DEADLINE=$((SECONDS + GUARD_SECONDS))
  guard_start || return 1
  if ! access_wait_verify login root-ssh || ! access_root_cutover || ! access_wait_verify final root-ssh; then
    guard_abort
    return 1
  fi
  guard_confirm || return 1
  log_ok "root SSH 已关闭；$user 的新 SSH 连接和 sudo 已验证。可在 [25] 回滚。"
)

access_setup() (
  local user=${1:-} keytmp newga temp_dir original_root
  if access_active; then
    log_info "已启用普通用户模式：$(access_user)。绑定管理见 [07]；退出模式请在 [25] 回滚原迁移记录。"
    return 0
  fi
  title "普通用户 SSH：密钥 + 密码 + TOTP；sudo：密码 + TOTP"
  echo '此方案要求已有完整 sudo 管理权限的本地普通用户。'
  if [[ -z $user ]]; then read -r -p "普通管理员用户名（回车取消）: " user || return 0; fi
  [[ -n $user ]] || return 0
  access_set_user "$user" || return 1
  if ! access_sudo_can_manage "$user" >/dev/null 2>&1; then
    log_err "$user 没有可确认的 sudo 管理权限。只配置 SSH 请使用 [06] 的 [1]–[4]；启用管理员方案前可在 [7] 授权。"
    return 1
  fi
  ga_install && access_sudo_preflight "$user" && access_ssh_preflight "$user" || return 1
  local path
  for path in "$SSHD_CONFIG" "$PAM_SSHD" "$PAM_ACCESS_SSH" "$PAM_ACCESS_LEGACY" \
    "$ACCESS_KEY_FILE" "$ACCESS_GA_FILE" "$ACCESS_STATE"; do access_safe_path "$path" || return 1; done
  time_synced || { log_err "先启用并确认系统时间同步，再配置动态口令"; return 1; }
  temp_dir=$(mktemp -d) || return 1
  trap 'rm -rf -- "$temp_dir"' EXIT
  keytmp="$temp_dir/authorized_keys"
  access_read_public_key "$user" "$keytmp" || return 1
  local GA_FILE="$temp_dir/totp" GA_ACCOUNT="$user"
  newga=$(ga_bind_new) || return 1
  echo
  echo "将先启用 $user 的公钥、账户密码与 TOTP，以及每次 sudo 的密码与 TOTP（无认证缓存）。"
  echo "新 SSH 会话验证成功后才禁止 root SSH；最终配置还要再建立新连接确认。"
  echo "每次新的 sudo 调用会认证；已打开的 root shell、root 权限程序或 vhm 菜单内的操作不逐条重新认证。"
  echo "其他用户的原 SSH 认证路径保留，sudo 规则中存在免认证或自定义策略时本向导拒绝迁移。"
  confirm_yes "已打开 VNC 应急控制台，开始迁移？" || return 0
  original_root=$(sshd_eff_for root) || return 1
  change_begin "普通管理员 $user：SSH 三项验证、sudo 双项验证、关闭 root SSH" sshd
  if ! access_track || ! access_record_admin_dependency "$user"; then change_status rolled_back; log_err "无法完整备份配置，未开始迁移"; return 1; fi
  guard_start || return 1
  ACCESS_DEADLINE=$((SECONDS + GUARD_SECONDS))
  if ! { install -d -o root -g root -m 755 "$ACCESS_KEYS_DIR" &&
    install -d -o root -g root -m 700 "$ACCESS_SECRETS_DIR" "$ACCESS_SECRETS_DIR/$user" &&
    install -o root -g root -m 644 "$keytmp" "$ACCESS_KEY_FILE" &&
    install -o root -g root -m 600 "$newga" "$ACCESS_GA_FILE" &&
    access_sudo_apply "$user" "$ACCESS_GA_FILE" && access_ssh_apply "$user" &&
    kv_set "$ACCESS_STATE" ACCESS_USER "$user" && kv_set "$ACCESS_STATE" ACCESS_CHANGE "$CHG_ID" &&
    access_ssh_expect "$user"; }; then guard_abort; return 1; fi
  # 第一步不能改变 root 的生效登录方式。其他用户由 PAM 分支保留原栈。
  local root_now key before after
  root_now=$(sshd_eff_for root) || { guard_abort; return 1; }
  for key in authenticationmethods passwordauthentication pubkeyauthentication kbdinteractiveauthentication permitrootlogin; do
    before=$(awk -v k="$key" '$1 == k { print $2 }' <<<"$original_root")
    after=$(awk -v k="$key" '$1 == k { print $2 }' <<<"$root_now")
    [[ $before == "$after" ]] || { log_err "第一阶段改变了 root 的登录方式，正在回滚"; guard_abort; return 1; }
  done
  ssh_reload && access_wait_verify login || { guard_abort; return 1; }
  log_info "普通用户登录与 sudo 已确认，现在关闭 root SSH"
  access_disable_root "$user" && ssh_reload && access_wait_verify final || { guard_abort; return 1; }
  guard_confirm || return 1
  log_ok "普通用户模式已启用；root SSH 已禁止，sudo 每次要求账户密码和 TOTP。可在 [25] 回滚本次迁移。"
)

access_tfa_manage() (
  local user choice codes newga
  user=$(access_user) && access_set_user "$user" || return 1
  local GA_FILE="$ACCESS_GA_FILE" GA_ACCOUNT="$user"
  title "$user 的动态口令（SSH / sudo 共用）"
  echo "  [1] 显示绑定二维码   [2] 重新绑定   [3] 查看剩余应急码   [0] 返回"
  echo "关闭此模式请在 [25] 回滚迁移记录；不会单独移除必需的认证项。"
  read -r -p "请选择：" choice || return 0
  case $choice in
    1)
      confirm_yes "二维码等同动态口令密钥，确认显示？" && ga_show_qr "$GA_FILE"
      ;;
    2)
      local temp_dir
      access_safe_path "$ACCESS_GA_FILE" && time_synced &&
        access_profile_verify "$user" key_password_totp "$ACCESS_KEY_FILE" "$ACCESS_GA_FILE" && access_ssh_expect "$user" &&
        access_sudo_verify "$user" "$ACCESS_GA_FILE" || { log_err '当前路径、时间同步或认证配置校验失败，未重新绑定'; return 1; }
      temp_dir=$(mktemp -d) || return 1
      trap 'rm -rf -- "$temp_dir"' EXIT
      local GA_FILE="$temp_dir/totp"
      newga=$(ga_bind_new) || return 1
      confirm_yes "同时更换 $user 的 SSH 与 sudo 动态口令？" || return 0
      change_begin "重新绑定 $user 的 SSH / sudo 动态口令"
      change_track "$ACCESS_GA_FILE" || { change_status rolled_back; return 1; }
      guard_start || return 1
      ACCESS_DEADLINE=$((SECONDS + GUARD_SECONDS))
      install -o root -g root -m 600 "$newga" "$ACCESS_GA_FILE" && access_wait_verify final || { guard_abort; return 1; }
      guard_confirm
      ;;
    3)
      confirm_yes "显示一次性应急码？" || return 0
      codes=$(grep -E '^[0-9]{8}$' "$ACCESS_GA_FILE" || true)
      if [[ -n $codes ]]; then printf '%s\n' "$codes"; else log_warn "应急码已用完，请重新绑定"; fi
      ;;
  esac
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  case ${1:-setup} in
    setup) need_root; with_lock access_setup ;;
    auth-menu) need_root; with_lock access_auth_menu ;;
    2fa-menu) need_root; with_lock access_profile_tfa_menu ;;
    verify) shift; access_verify "$@" ;;
    2fa-manage) need_root; with_lock access_tfa_manage ;;
    *) die "未知参数：$1" ;;
  esac
fi
