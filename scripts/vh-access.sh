#!/usr/bin/env bash
# 可选的普通用户 SSH 三项验证与 sudo 双项验证迁移。只操作已有管理员，不创建或扩权账户。
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-ssh.sh
source "$VH_DIR/vh-ssh.sh"

ACCESS_PASSWD_FILE=${ACCESS_PASSWD_FILE:-/etc/passwd}

access_set_user() {
  local user=$1 entry resolved uid gid home shell
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $user != root ]] || { log_err "请选择普通本地用户（不支持 root）"; return 1; }
  entry=$(awk -F: -v u="$user" '$1 == u { print }' "$ACCESS_PASSWD_FILE") || return 1
  resolved=$(getent passwd "$user") || return 1
  [[ -n $entry && $entry == "$resolved" && $entry != *$'\n'* ]] || { log_err "用户必须来自本地 passwd 数据库"; return 1; }
  IFS=: read -r _ _ uid gid _ home shell <<<"$entry"
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $uid -ge 1000 && $uid -lt 65534 && $home == /* ]] || { log_err "请选择 UID 1000–65533 的普通用户"; return 1; }
  awk -F: -v uid="$uid" '$3 == uid { n++ } END { exit n != 1 }' "$ACCESS_PASSWD_FILE" || { log_err '该 UID 对应多个账户，请先人工整理'; return 1; }
  grep -Fxq -- "$shell" /etc/shells && [[ $shell != */nologin && $shell != */false ]] || { log_err "该用户没有可用的交互 shell"; return 1; }
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
  local user=$1 addr connection_text=${SSH_CONNECTION:-}
  access_profile_disable_root "$user" && access_ssh_expect "$user" || return 1
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

access_choose_user() {
  local choice user
  echo '  [1] root    [2] 普通用户    [0] 返回' >&2
  read -r -p '选择要配置的用户类型: ' choice || return 1
  case $choice in
    1) printf 'root\n' ;;
    2)
      read -r -p '已有普通用户的用户名: ' user || return 1
      access_set_user "$user" >&2 || return 1
      printf '%s\n' "$user"
      ;;
    *) return 1 ;;
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
  local user=$1 mode=$2 path eff temp_dir newga="" keytmp="" password_status permit=""
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
    password_status=$(LC_ALL=C passwd -S "$user" 2>/dev/null | awk '{print $2}')
    [[ $password_status == P ]] || { log_err "$user 尚无可用账户密码，请先设置密码"; return 1; }
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
  user=$(access_choose_user) || return 0
  title "$user 的 SSH 登录方式"
  echo "已单独配置：$(access_profile_get "$user" 2>/dev/null || echo '沿用原 SSH 配置')"
  echo '  [1] 密码登录（不建议）'
  echo '  [2] 密钥登录'
  echo '  [3] 密码 + 2FA（TOTP）'
  echo '  [4] 密钥 + 2FA（TOTP）'
  echo "  [5] 修改 $user 的系统密码"
  [[ $user == root ]] || echo '  [6] 普通管理员：密钥 + 密码 + TOTP；sudo 每次密码 + TOTP；验证后禁 root SSH'
  echo '  [0] 返回'
  read -r -p '请选择：' choice || return 0
  case $choice in
    1) access_profile_configure "$user" password ;;
    2) access_profile_configure "$user" key ;;
    3) access_profile_configure "$user" password_totp ;;
    4) access_profile_configure "$user" key_totp ;;
    5) confirm_yes "通过 passwd 修改 $user 的账户密码？不保存密码，不能回滚。" && passwd "$user" ;;
    6) [[ $user == root ]] || access_setup "$user" ;;
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

# 用 /proc 中真实的 sshd 进程识别会话，sudo env_reset 无需保留 SSH_CONNECTION。
# 新连接的 sshd 子进程必须比当前阶段更晚启动，拒绝旧会话/ControlMaster 复用。
access_session() { # access_session 用户 UID；输出 sshd-pid:start-ticks
  python3 - "$1" "$2" "$$" <<'PY'
import os, sys
user, uid, pid = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
seen = set()
while pid > 1 and pid not in seen:
    seen.add(pid)
    try:
        status = dict(line.split(':', 1) for line in open(f'/proc/{pid}/status') if ':' in line)
        exe = os.path.basename(os.readlink(f'/proc/{pid}/exe'))
        args = open(f'/proc/{pid}/cmdline', 'rb').read().replace(b'\0', b' ').decode(errors='replace')
        euid = int(status['Uid'].split()[1])
        stat = open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split()
        if exe in ('sshd', 'sshd-session') and euid == uid and f'{user}@' in args:
            print(f'{pid}:{stat[19]}')
            sys.exit(0)
        pid = int(status['PPid'].strip())
    except (OSError, ValueError, KeyError):
        break
sys.exit(1)
PY
}

access_ticks() { python3 -c 'import os; print(int(float(open("/proc/uptime").read().split()[0]) * os.sysconf("SC_CLK_TCK")))'; }

access_verify() {
  local id=${1:-} phase=${2:-} dir user session cutoff
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
  access_profile_verify "$user" key_password_totp "$ACCESS_KEY_FILE" "$ACCESS_GA_FILE" &&
    access_ssh_expect "$user" && access_sudo_verify "$user" "$ACCESS_GA_FILE" || return 1
  [[ $phase != final ]] || access_expect_for root 203.0.113.1 permitrootlogin no || return 1
  printf '%s\n' "$session" | access_write "$dir/access-verified-$phase" 600 || return 1
  log_ok "普通用户的新 SSH 会话和 sudo 调用已验证，请回到原窗口继续"
}

access_wait_verify() {
  local phase=$1 ans user=$ACCESS_USER port remaining
  [[ -n ${ACCESS_DEADLINE:-} ]] || ACCESS_DEADLINE=$((SECONDS + GUARD_SECONDS))
  remaining=$((ACCESS_DEADLINE - SECONDS))
  ((remaining > 0)) || { log_err '迁移保护时间已到，正在回滚'; guard_abort; return 1; }
  port=$(cur_ports | head -n1)
  printf '%s\n' "$user" >"$CHG_DIR/access-user" &&
    printf '%s\n' "$phase" >"$CHG_DIR/access-phase" &&
    access_ticks >"$CHG_DIR/access-cutoff" || return 1
  echo
  echo "保持本窗口；另开一个新的 SSH 连接（禁用连接复用）："
  echo "  ssh -o ControlMaster=no -o ControlPath=none -p $port $user@$(server_ip)"
  echo "依次通过公钥、账户密码和动态验证码，然后直接执行："
  echo "  sudo /usr/local/bin/vhm access-verify $CHG_ID $phase"
  echo "sudo 必须再次要求账户密码和动态验证码；验证码已用于登录时，请等下一组。"
  echo "不要进入 sudo -i / su；确认每项都被要求后回到这里。"
  echo "本次迁移的保护时间共 $GUARD_SECONDS 秒，当前剩余 $remaining 秒。"
  read -r -t "$remaining" -p "新窗口验证完成后输入 yes（其他输入回滚）: " ans || ans=""
  if [[ ${ans,,} != yes || ! -s $CHG_DIR/access-verified-$phase || $(cat "$CHG_DIR/status") != pending ]] || ((SECONDS >= ACCESS_DEADLINE)); then
    log_err "新会话验证未完成，正在回滚"
    guard_abort
    return 1
  fi
}

access_setup() (
  local user=${1:-} keytmp newga temp_dir original_root
  if access_active; then
    log_info "已启用普通用户模式：$(access_user)。绑定管理见 [07]；退出模式请在 [25] 回滚原迁移记录。"
    return 0
  fi
  title "普通用户 SSH：密钥 + 密码 + TOTP；sudo：密码 + TOTP"
  echo "使用已有的普通 sudo 管理员，不创建用户、不修改其系统密码。"
  echo "没有管理员时，请先通过系统 adduser / usermod 配置，并确认已设置账户密码。"
  if [[ -z $user ]]; then read -r -p "普通管理员用户名（回车取消）: " user || return 0; fi
  [[ -n $user ]] || return 0
  access_set_user "$user" || return 1
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
  if ! access_track; then change_status rolled_back; log_err "无法完整备份配置，未开始迁移"; return 1; fi
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
