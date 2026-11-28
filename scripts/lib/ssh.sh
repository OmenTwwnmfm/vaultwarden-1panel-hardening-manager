# shellcheck shell=bash
# shellcheck disable=SC2034
# SSH 生效配置读取、服务重载与 2FA 状态；由 vh-common.sh 加载，不要单独执行

# ---------- SSH ----------
access_user() {
  local user
  user=$(conf_get ACCESS_USER "$ACCESS_STATE") || return 1
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $user != root ]] || return 1
  printf '%s\n' "$user"
}
access_active() { [[ -n $(access_user) ]]; }

# 显示原始 SSH 登录账户；sudo/su 后仍沿用实际连接进程的身份，不读取登录环境变量。
ssh_login_user() { _ssh_login_identity '' ''; }

_ssh_login_identity() { # [预期用户名 UID]；传入时返回 sshd-pid:start-ticks
  python3 - "$1" "$2" 2>/dev/null <<'PY'
import os
import pwd
import re
import stat
import sys

title = re.compile(rb'(sshd(?:-session)?): ([A-Za-z0-9_][A-Za-z0-9_.-]{0,63}\$?)(?:@(?:notty|pts/[0-9]+(?:,pts/[0-9]+)*))?')
expected = sys.argv[1:]
pid = os.getppid()
seen = set()
while pid > 1 and pid not in seen and len(seen) < 128:
    seen.add(pid)
    path = f'/proc/{pid}'
    try:
        with open(path + '/status', encoding='ascii', errors='replace') as stream:
            status = dict(line.split(':', 1) for line in stream if ':' in line)
        pid = int(status['PPid'])
        executable = re.sub(r' \(deleted\)$', '', os.path.basename(os.readlink(path + '/exe')))
        if executable not in ('sshd', 'sshd-session'):
            continue
        binary = os.stat(path + '/exe')
        if not stat.S_ISREG(binary.st_mode) or binary.st_uid != 0 or binary.st_mode & 0o022:
            continue
        with open(path + '/cmdline', 'rb') as stream:
            command, separator, _ = stream.read(2048).partition(b'\0')
        match = title.fullmatch(command.rstrip(b' ')) if separator else None
        if not match:
            continue
        program, username = (value.decode('ascii') for value in match.groups())
        if program != executable:
            continue
        real_uid, effective_uid = map(int, status['Uid'].split()[:2])
        account = pwd.getpwnam(username)
        if account.pw_name != username or account.pw_uid != real_uid or real_uid != effective_uid:
            continue
        if expected[0]:
            if expected != [username, str(real_uid)]:
                sys.exit(1)
            with open(path + '/stat', encoding='ascii', errors='replace') as stream:
                started = stream.read().rsplit(')', 1)[1].split()[19]
            print(f'{path.rsplit("/", 1)[1]}:{int(started)}')
        else:
            print(username)
        sys.exit(0)
    except (OSError, IndexError, KeyError, ValueError):
        continue
sys.exit(1)
PY
}

# 变更验收必须按指定用户和真实连接上下文核对；失败不能退回无 Match 上下文的 -T。
sshd_eff_for() { # sshd_eff_for 用户 [来源地址]
  local user=$1 addr=${2:-} local_addr local_port out
  local connection=()
  read -r -a connection <<<"${SSH_CONNECTION:-}"
  [[ -n $addr ]] || addr=${connection[0]:-203.0.113.1}
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  [[ $addr =~ ^[0-9a-fA-F:.]+$ ]] || addr=203.0.113.1
  local_addr=${connection[2]:-127.0.0.1}
  local_port=${connection[3]:-22}
  mkdir -p /run/sshd 2>/dev/null
  out=$("$SSHD_BIN" -T -C "user=$user,host=vhm-check,addr=$addr,laddr=$local_addr,lport=$local_port" 2>/dev/null) || return 1
  [[ -n $out ]] || return 1
  awk '{ $1 = tolower($1); print }' <<<"$out"
}

if [[ -z ${SSHD_BIN:-} ]]; then
  if [[ -x /usr/sbin/sshd ]]; then SSHD_BIN=/usr/sbin/sshd; else SSHD_BIN=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd); fi
fi
sshd_test() { mkdir -p /run/sshd 2>/dev/null; "$SSHD_BIN" -t 2>&1; }
# 生效配置：优先按当前 SSH 客户端的真实来源地址计算（让 Match 块生效）；
# 从控制台 / VNC 运行时没有来源地址，用一个文档保留地址代替。不支持 -C 时退回 sshd -T。
sshd_eff() {
  local out addr user
  mkdir -p /run/sshd 2>/dev/null
  addr=${SSH_CONNECTION:-}
  addr=${addr%% *}
  if [[ -z $addr ]]; then
    addr=$(who am i 2>/dev/null | awk '{ print $NF }' | tr -d '()')
  fi
  [[ $addr =~ ^[0-9a-fA-F:.]+$ ]] || addr=203.0.113.1
  user=$(access_user) || user=root
  out=$("$SSHD_BIN" -T -C "user=$user,host=vhm-check,addr=$addr" 2>/dev/null) || out=""
  [[ -n $out ]] || out=$("$SSHD_BIN" -T 2>/dev/null) || out=""
  # OpenSSH 10.x 的 sshd -T 输出配置名用驼峰（Port、PasswordAuthentication），旧版是全小写；统一转成小写
  [[ -n $out ]] && awk '{ $1 = tolower($1); print }' <<<"$out"
}
sshd_eff_err() { mkdir -p /run/sshd 2>/dev/null; "$SSHD_BIN" -T 2>&1 >/dev/null | tail -n 3; }

# sshd -T 失败时，直接解析配置文件得到同样格式的「键 值」行（含 Include，遇到 Match 停止，未设置的用 OpenSSH 默认值）。
# 只用于显示和判断状态；修改 SSH 时的生效值校验仍然只认 sshd -T。
sshd_conf_view() {
  python3 - "$SSHD_CONFIG" <<'PY'
import glob, os, re, sys
defaults = {"passwordauthentication": "yes", "pubkeyauthentication": "yes", "permitrootlogin": "prohibit-password",
            "kbdinteractiveauthentication": "yes", "usepam": "no", "authenticationmethods": "any"}
alias = {"challengeresponseauthentication": "kbdinteractiveauthentication"}
vals, ports = {}, []
def walk(path, depth=0):
    if depth > 8:
        return
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return
    for line in lines:
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        parts = re.split(r"[\s=]+", s, maxsplit=1)
        k = alias.get(parts[0].lower(), parts[0].lower())
        v = parts[1].strip() if len(parts) > 1 else ""
        if k == "match":
            return
        if k == "include":
            for pat in v.split():
                if not os.path.isabs(pat):
                    pat = os.path.join("/etc/ssh", pat)
                for f in sorted(glob.glob(pat)):
                    walk(f, depth + 1)
        elif k == "port":
            ports.append(v)
        elif k in defaults:
            vals.setdefault(k, v.lower())  # sshd 对同一配置项取第一个值
walk(sys.argv[1])
for p in ports or ["22"]:
    print("port", p)
for k, d in defaults.items():
    print(k, vals.get(k, d))
PY
}

# 显示用的生效配置：sshd -T 优先，失败时退回解析配置文件
sshd_view() {
  local out
  out=$(sshd_eff) || out=""
  [[ -n $out ]] || out=$(sshd_conf_view 2>/dev/null) || out=""
  [[ -n $out ]] && printf '%s\n' "$out"
}
sshd_view_src() { if [[ -n $(sshd_eff) ]]; then echo "sshd -T"; else echo "配置文件（sshd -T 失败）"; fi; }
sshd_get() {
  local out
  out=$(sshd_view) || out=""
  awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }' <<<"$out"
}
ssh_service() { if systemctl cat ssh.service >/dev/null 2>&1; then echo ssh; else echo sshd; fi; }
ssh_socket_used() { systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; }

ssh_reload() {
  local out svc
  out=$(sshd_test) || { log_err "sshd 配置检查未通过：$out"; return 1; }
  svc=$(ssh_service)
  if ssh_socket_used; then
    systemctl daemon-reload || return 1
    systemctl restart ssh.socket || return 1
    systemctl try-restart "$svc" || return 1
  elif systemctl is-active --quiet "$svc"; then
    systemctl reload "$svc" || systemctl restart "$svc" || return 1
  else
    systemctl start "$svc" || return 1
  fi
}

ssh_pam_auth_file() {
  local user
  user=$(access_user) || user=root
  if access_profile_get "$user" >/dev/null 2>&1; then
    access_profile_pam "$user"
  elif [[ -f $(access_profile_state) && -f $PAM_ACCESS_LEGACY ]]; then
    printf '%s\n' "$PAM_ACCESS_LEGACY"
  else
    printf '%s\n' "$PAM_SSHD"
  fi
}
tfa_pam_lines() {
  local pam
  pam=$(ssh_pam_auth_file)
  grep -E '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_google_authenticator\.so' "$pam" 2>/dev/null
}
# 带 nullok 时未绑定动态口令也可以跳过，不能算真正启用
tfa_pam_on() {
  local lines
  lines=$(tfa_pam_lines) || return 1
  grep -qv 'nullok' <<<"$lines"
}
tfa_pam_nullok() {
  local lines
  lines=$(tfa_pam_lines) || return 1
  grep -q 'nullok' <<<"$lines"
}
tfa_enabled() {
  local mode
  mode=$(sshd_get authenticationmethods)
  tfa_pam_on && [[ $mode == *keyboard-interactive* ]]
}

ssh_auth_mode() {
  local methods password pubkey tfa common_auth pam
  methods=$(sshd_get authenticationmethods)
  password=$(sshd_get passwordauthentication)
  pubkey=$(sshd_get pubkeyauthentication)
  tfa=$(tfa_pam_on && echo yes || echo no)
  pam=$(ssh_pam_auth_file)
  common_auth=no
  if grep -Eq '^[[:space:]]*(@include[[:space:]]+common-auth|auth[[:space:]]+substack[[:space:]]+common-auth)' "$pam" 2>/dev/null; then common_auth=yes; fi
  if [[ $tfa == yes && $methods == *publickey,keyboard-interactive* ]]; then
    if [[ $common_auth == yes ]]; then echo key_password_totp; else echo key_totp; fi
  elif [[ $tfa == yes && ( $methods == keyboard-interactive || $methods == keyboard-interactive:pam ) ]]; then
    if [[ $common_auth == yes ]]; then echo password_totp; else echo totp_only; fi
  elif [[ $methods == publickey && $pubkey == yes ]]; then echo key
  elif [[ $methods == password && $password == yes ]]; then echo password
  elif [[ $methods == any && $password == yes && $pubkey == yes ]]; then echo mixed
  else echo custom
  fi
}
