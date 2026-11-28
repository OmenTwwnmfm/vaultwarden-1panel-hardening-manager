# shellcheck shell=bash
# 每个本地用户独立的 SSH 登录方式；只生成认证配置，不授予账号或 sudo 权限。
# 调用方负责：change_begin/完整快照/guard_start、安装 key/seed、启用 UsePAM、重载及新连接验收。

_access_profile_owner_uid() { printf '0\n'; }

access_profile_state() { printf '%s\n' "${ACCESS_PROFILES_STATE:-$VH_STATE/ssh-profiles.json}"; }
access_profile_pam() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  printf '%s%s\n' "${PAM_PROFILE_PREFIX:-$(dirname "$PAM_ACCESS_SSH")/vhm-ssh-user-}" "$1"
}

_access_profile_modules() {
  local mode=$1 name path found
  local modules=(pam_succeed_if pam_deny pam_permit)
  case $mode in password|password_totp|key_password_totp) modules+=(pam_unix) ;; esac
  case $mode in *_totp) modules+=(pam_google_authenticator) ;; esac
  for name in "${modules[@]}"; do
    found=0
    for path in /lib/security/"$name.so" /usr/lib/security/"$name.so" /lib/*/security/"$name.so" /usr/lib/*/security/"$name.so"; do
      if [[ -f $path ]]; then found=1; break; fi
    done
    ((found)) || { log_err "缺少 $name.so，未更改 SSH 登录方式"; return 1; }
  done
}

_access_profile_policy() {
  local operation=$1 user=${2:-} mode=${3:-} key=${4:-} secret=${5:-} root_policy=${6:-}
  python3 - "$operation" "$user" "$mode" "$key" "$secret" "$root_policy" "$(_access_profile_owner_uid)" \
    "$SSHD_CONFIG" "$PAM_SSHD" "$PAM_ACCESS_LEGACY" "$(access_profile_state)" \
    "${PAM_PROFILE_PREFIX:-$(dirname "$PAM_ACCESS_SSH")/vhm-ssh-user-}" \
    "${PAM_COMMON_AUTH:-$(dirname "$PAM_SSHD")/common-auth}" <<'PY'
import glob
import json
import os
import re
import shlex
import stat
import sys
import tempfile
from pathlib import Path

(operation, user, mode, key, secret, requested_root_policy, owner, ssh_config, pam_service, pam_legacy,
 state_file, profile_prefix, common_auth) = sys.argv[1:]
owner = int(owner)
MODES = {'password', 'key', 'password_totp', 'key_totp', 'key_password_totp'}
ROOT_POLICIES = ('no', 'yes', 'prohibit-password')
BEGIN_SSH = '# BEGIN vhm user profiles'
END_SSH = '# END vhm user profiles'
BEGIN_PAM = '# BEGIN vhm user authentication'
END_PAM = '# END vhm user authentication'
HEADER = '# Managed by vaultwarden-hardening-manager; do not edit.\n'

def refuse(message):
    raise ValueError(message)

def safe_path(value):
    if (not re.fullmatch(r'/[A-Za-z0-9_./-]+', value) or '//' in value or
            any(part in ('.', '..') for part in value.split('/'))):
        refuse('配置路径必须是无空白、无转义的绝对路径')
    return Path(value)

def checked(value, missing=False, private=False, public=False):
    path = safe_path(str(value))
    parts = path.parts
    for index in range(1, len(parts)):
        current = Path(*parts[:index + 1])
        last = index == len(parts) - 1
        try:
            info = current.lstat()
        except FileNotFoundError:
            if missing:
                return path
            refuse('缺少配置：' + str(current))
        if stat.S_ISLNK(info.st_mode):
            refuse('拒绝符号链接配置：' + str(current))
        if not last:
            sticky_root = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, owner) or
                    (info.st_mode & 0o022 and not sticky_root)):
                refuse('配置目录属主、类型或权限不安全：' + str(current))
            if public and not info.st_mode & 0o001:
                refuse('普通用户不能遍历公钥目录：' + str(current))
        else:
            if not stat.S_ISREG(info.st_mode) or info.st_uid != owner or info.st_mode & 0o022:
                refuse('配置文件属主、类型或权限不安全：' + str(current))
            if private and (stat.S_IMODE(info.st_mode) not in (0o400, 0o600) or info.st_nlink != 1):
                refuse('TOTP 文件必须为 root 独占的 0600/0400 普通文件')
            if public and not info.st_mode & 0o004:
                refuse('集中公钥文件必须允许普通用户读取')
    return path

def text(value):
    return Path(value).read_text(encoding='utf-8')

def valid_user(value):
    return bool(re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', value))

def wants_key(value):
    return value in ('key', 'key_totp', 'key_password_totp')

def wants_password(value):
    return value in ('password', 'password_totp', 'key_password_totp')

def wants_totp(value):
    return value.endswith('_totp')

def profile_path(name):
    value = safe_path(profile_prefix + name)
    if (value.parent != Path(pam_service).parent or
            not re.fullmatch(r'[A-Za-z0-9_-]+', value.name) or
            value in (Path(pam_service), Path(pam_legacy), Path(common_auth))):
        refuse('每用户 PAM 文件必须位于 SSH PAM 目录且名称不可冲突')
    return value

def read_state():
    path = checked(state_file, missing=True, private=True)
    if not path.exists():
        return {}, ''
    data = json.loads(text(path))
    fields = {'version', 'profiles'}
    if not isinstance(data, dict) or set(data) not in (fields, fields | {'root_policy'}) or data['version'] != 1:
        refuse('SSH profile 元数据版本或结构不受支持')
    root_policy = data.get('root_policy', '')
    if root_policy not in ('', *ROOT_POLICIES):
        refuse('受管 root 登录开关无效')
    profiles = data['profiles']
    if not isinstance(profiles, dict) or len(profiles) > 64 or (not profiles and root_policy != 'no'):
        refuse('SSH profile 用户数量无效（最多 64 个）')
    for name, entry in profiles.items():
        if (not valid_user(name) or not isinstance(entry, dict) or
                set(entry) != {'mode', 'key', 'secret'} or entry['mode'] not in MODES):
            refuse('SSH profile 用户或记录结构无效')
        for field, required in (('key', wants_key(entry['mode'])), ('secret', wants_totp(entry['mode']))):
            if not isinstance(entry[field], str) or bool(entry[field]) != required:
                refuse('SSH profile 的认证项路径不完整')
            if required:
                safe_path(entry[field])
        profile_path(name)
    return profiles, root_policy

def read_secret(value):
    path = checked(value, private=True)
    directory = path.parent.stat()
    if directory.st_uid != owner or stat.S_IMODE(directory.st_mode) != 0o700:
        refuse('TOTP 文件的直接父目录必须由 root 所有且为 0700')
    # 只判断文件可用性；密钥、应急码与口令从不进入元数据或诊断。
    with path.open(encoding='ascii') as stream:
        first = stream.readline().strip()
    if not re.fullmatch(r'[A-Z2-7]{16,128}', first):
        refuse('TOTP 文件格式无效')

def check_common():
    lines = [' '.join(raw.split('#', 1)[0].split()) for raw in text(checked(common_auth)).splitlines()]
    lines = [line for line in lines if line]
    unix = r'auth \[success=1 default=ignore\] pam_unix\.so(?: (?:nullok|try_first_pass))*'
    if (len(lines) not in (3, 4) or not re.fullmatch(unix, lines[0]) or
            lines[1:3] != ['auth requisite pam_deny.so', 'auth required pam_permit.so'] or
            (len(lines) == 4 and lines[3] != 'auth optional pam_cap.so')):
        refuse('common-auth 不是受支持的 Debian/Ubuntu 本地密码认证栈，需先人工审核')

def render_helper(entry):
    lines = [HEADER.rstrip('\n')]
    if wants_password(entry['mode']) or not wants_totp(entry['mode']):
        lines.append('auth substack common-auth')
    if wants_totp(entry['mode']):
        lines.append('auth required pam_google_authenticator.so user=root secret=' + entry['secret'])
    return '\n'.join(lines) + '\n'

def render_dispatch(profiles):
    names = sorted(profiles)
    # OpenSSH may call setcred without a cached auth chain; pam_deny distinguishes CRED_ERR from AUTH_ERR.
    lines = [BEGIN_PAM,
             'auth [success=2 auth_err=2 ignore=ignore default=die] pam_succeed_if.so quiet user = root',
             'auth [cred_err=ignore default=die] pam_deny.so',
             'auth [success=done default=die] pam_permit.so']
    # 每个命中的子栈以 required/substack 结果累积；失败不能被后续分支覆盖。
    for name in names:
        lines += ['auth [success=ignore auth_err=1 default=die] pam_succeed_if.so quiet user = ' + name,
                  'auth substack ' + profile_path(name).name]
    # 已管用户跳过未管用户的原认证栈。auth_err 是普通不匹配；模块错误直接拒绝。
    for index, name in enumerate(names):
        lines.append('auth [success=' + str(len(names) - index) +
                     ' auth_err=ignore default=die] pam_succeed_if.so quiet user = ' + name)
    lines += ['auth substack ' + Path(pam_legacy).name, END_PAM]
    return '\n'.join(lines) + '\n'

def render_ssh(profiles, root_policy):
    lines = [BEGIN_SSH]
    names = set(profiles) | ({'root'} if root_policy else set())
    for name in sorted(names):
        lines.append('Match User ' + name)
        if name == 'root' and root_policy:
            lines.append('    PermitRootLogin ' + root_policy)
        if name not in profiles:
            continue
        entry = profiles[name]
        mode = entry['mode']
        methods = {'password': 'password', 'key': 'publickey', 'password_totp': 'keyboard-interactive:pam',
                   'key_totp': 'publickey,keyboard-interactive:pam',
                   'key_password_totp': 'publickey,keyboard-interactive:pam'}[mode]
        lines += ['    AuthenticationMethods ' + methods,
                  '    PasswordAuthentication ' + ('yes' if mode == 'password' else 'no'),
                  '    PubkeyAuthentication ' + ('yes' if wants_key(mode) else 'no'),
                  '    KbdInteractiveAuthentication ' + ('yes' if wants_totp(mode) else 'no'),
                  '    PermitEmptyPasswords no']
        if wants_key(mode):
            lines.append('    AuthorizedKeysFile ' + entry['key'])
    lines.append(END_SSH)
    return '\n'.join(lines) + '\n'

def split_managed(content, begin, end):
    lines = content.splitlines(keepends=True)
    first = [index for index, line in enumerate(lines) if line.rstrip('\r\n') == begin]
    last = [index for index, line in enumerate(lines) if line.rstrip('\r\n') == end]
    if not first and not last:
        return content, ''
    if len(first) != 1 or len(last) != 1 or first[0] >= last[0]:
        refuse('受管认证块标记损坏或重复')
    return ''.join(lines[:first[0]]) + ''.join(lines[last[0] + 1:]), ''.join(lines[first[0]:last[0] + 1])

def check_ssh(profiles, root_policy):
    original = text(checked(ssh_config))
    base, block = split_managed(original, BEGIN_SSH, END_SSH)
    if profiles or root_policy:
        if block != render_ssh(profiles, root_policy) or not original.rstrip().endswith(END_SSH):
            refuse('SSH 受管 Match 块被修改或不在主配置尾部')
    elif block:
        refuse('存在无元数据的 SSH 受管配置，请先回滚或人工审核')
    active, seen = set(), set()
    def walk(value, content=None, depth=0):
        path = checked(value)
        if depth > 16 or len(seen) >= 128 or path in active or path in seen:
            refuse('SSH Include 循环、重复或数量过多')
        active.add(path)
        seen.add(path)
        for raw in (text(path) if content is None else content).splitlines():
            parts = shlex.split(raw, comments=True)
            if not parts:
                continue
            parts = re.split('=', parts[0], maxsplit=1) + parts[1:]
            keyword, arguments = parts[0].lower(), parts[1:]
            if keyword == 'match':
                refuse('存在不受管理的 SSH Match，需人工审核：' + str(path))
            if keyword == 'include':
                for pattern in arguments:
                    if not os.path.isabs(pattern):
                        pattern = os.path.join('/etc/ssh', pattern)
                    for child in sorted(glob.glob(pattern)):
                        walk(child, depth=depth + 1)
        active.remove(path)
    walk(ssh_config, base)
    return base

def check_pam(profiles):
    original = text(checked(pam_service))
    base, block = split_managed(original, BEGIN_PAM, END_PAM)
    if profiles:
        if block != render_dispatch(profiles):
            refuse('SSH PAM 派发块被修改，需人工审核')
        checked(pam_legacy)
        for name, entry in profiles.items():
            if text(checked(profile_path(name))) != render_helper(entry):
                refuse('每用户 SSH PAM 子栈被修改：' + name)
    elif block or Path(pam_legacy).exists():
        refuse('存在无元数据的旧 PAM 迁移，请先回滚或人工审核')
    auth, retained, insertion = [], [], None
    common_count = 0
    for original_line in base.splitlines():
        line = original_line.strip()
        commented = line.startswith('#vhm# ')
        active_line = line[len('#vhm# '):].strip() if commented else line
        common = bool(re.fullmatch(r'@include\s+common-auth|auth\s+substack\s+common-auth', active_line))
        auth_line = bool(re.match(r'-?auth\b', active_line, flags=re.I))
        if not line.startswith('#') and line.endswith('\\'):
            refuse('SSH PAM 含不受支持的续行')
        if common or auth_line:
            if profiles:
                refuse('SSH PAM 受管块外存在额外 auth 路径')
            if not common and active_line != 'auth required pam_google_authenticator.so':
                refuse('SSH PAM 含无法安全迁移的自定义认证：' + active_line)
            if commented and not common:
                retained.append(original_line)
                continue
            common_count += int(common)
            auth.append(original_line)
            if insertion is None:
                insertion = len(retained)
        elif line.lower().startswith('@include'):
            include = re.fullmatch(r'@include\s+(common-(account|password|session)(?:-noninteractive)?)', line)
            if not include or (include[1].endswith('-noninteractive') and include[2] != 'session'):
                refuse('SSH PAM 有不受支持的 include')
            if profiles and operation in ('verify', 'disable-root'):
                refuse('SSH PAM 受管块外存在未限制类型的 include')
            # PAM 的 @include 会包含所有类型；只保留非 auth 文件原本的账户、密码或会话规则。
            retained.append(f'{include[2]} include {include[1]}')
        else:
            retained.append(original_line)
    if not profiles and common_count != 1:
        refuse('SSH PAM 必须只有一处标准 common-auth（允许旧 vhm 注释）')
    if profiles:
        # 保留派发块原位置，尤其是后面的 account/session 模块。
        insertion = len(original.split(BEGIN_PAM, 1)[0].splitlines())
    return retained, insertion, auth

def atomic_write(value, content, permissions):
    target = checked(value, missing=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.vhm-profile-', dir=target.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            stream.write(content)
            stream.flush()
            os.fchmod(stream.fileno(), permissions)
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def ensure_state_parent():
    # change_begin 通常已创建 VH_STATE；不修改既有目录权限。
    state_parent = Path(state_file).parent
    if not state_parent.exists():
        state_parent.mkdir(mode=0o700, parents=True)
    checked(state_file, missing=True, private=True)

def write_ssh_state(base, profiles, root_policy):
    state = {'version': 1, 'profiles': profiles}
    if root_policy:
        state['root_policy'] = root_policy
    atomic_write(ssh_config, base.rstrip('\n') + '\n\n' + render_ssh(profiles, root_policy), 0o600)
    atomic_write(state_file, json.dumps(state, ensure_ascii=False, sort_keys=True, indent=2) + '\n', 0o600)

try:
    profiles, root_policy = read_state()
    if operation == 'root-policy':
        if not root_policy:
            sys.exit(1)
        print(root_policy)
        sys.exit(0)
    if operation in ('root-check', 'root-apply'):
        ssh_base = check_ssh(profiles, root_policy)
        if operation == 'root-apply' and root_policy != 'no':
            ensure_state_parent()
            write_ssh_state(ssh_base, profiles, 'no')
        sys.exit(0)
    if operation == 'get':
        if user in profiles:
            print(profiles[user]['mode'])
        else:
            sys.exit(1)
        sys.exit(0)
    if operation == 'list':
        for name in sorted(profiles):
            print(name + '\t' + profiles[name]['mode'])
        sys.exit(0)
    if operation == 'paths':
        if not valid_user(user):
            refuse('无效的 SSH profile 用户')
        for path in (ssh_config, pam_service, pam_legacy, state_file):
            print(path)
        for name in sorted(set(profiles) | {user}):
            print(profile_path(name))
        sys.exit(0)
    if operation not in ('check', 'apply', 'verify', 'disable-root') or not valid_user(user) or mode not in MODES:
        refuse('无效的用户 SSH profile 操作')
    if requested_root_policy:
        if (operation != 'apply' or user != 'root' or
                requested_root_policy != ('prohibit-password' if mode == 'key' else 'yes')):
            refuse('仅能在明确配置 root 登录方式时设置对应的 root 登录开关')
        if root_policy == 'no':
            refuse('本工具已关闭 root SSH；请先回滚关闭 root SSH 的变更')
    profile_path(user)
    ssh_base = check_ssh(profiles, root_policy)
    retained, insertion, old_auth = check_pam(profiles)
    if wants_password(mode) or any(wants_password(entry['mode']) for entry in profiles.values()):
        check_common()
    for name, entry in profiles.items():
        if wants_key(entry['mode']):
            checked(entry['key'], public=name != 'root')
        if wants_totp(entry['mode']):
            read_secret(entry['secret'])
    if operation == 'check':
        sys.exit(0)
    if operation == 'disable-root':
        if user == 'root' or profiles.get(user, {}).get('mode') != 'key_password_totp':
            refuse('必须先配置替代 root SSH 的普通管理员')
        write_ssh_state(ssh_base, profiles, 'no')
        sys.exit(0)
    expected_profile = {'mode': mode, 'key': key if wants_key(mode) else '', 'secret': secret if wants_totp(mode) else ''}
    if operation == 'verify':
        if profiles.get(user) != expected_profile:
            refuse('用户受管 SSH 登录方式、公钥或 TOTP 文件路径与预期不一致')
        sys.exit(0)
    if wants_key(mode):
        checked(key, public=user != 'root')
    if wants_totp(mode):
        read_secret(secret)
    updated = dict(profiles)
    updated[user] = expected_profile
    if len(updated) > 64:
        refuse('最多支持 64 个独立登录用户')
    target = profile_path(user)
    if not profiles:
        # 不覆盖未知的同名子栈或 legacy；回滚时它们均作为新文件移除。
        checked(pam_legacy, missing=True)
    if target.exists() and user not in profiles:
        refuse('已有同名每用户 PAM 文件，拒绝覆盖')
    ensure_state_parent()
    if not profiles:
        atomic_write(pam_legacy, HEADER + '\n'.join(old_auth) + '\n', 0o644)
    atomic_write(target, render_helper(updated[user]), 0o644)
    pam_lines = retained[:insertion] + render_dispatch(updated).rstrip('\n').splitlines() + retained[insertion:]
    atomic_write(pam_service, '\n'.join(pam_lines) + '\n', 0o644)
    write_ssh_state(ssh_base, updated, requested_root_policy or root_policy)
except (ValueError, OSError, UnicodeError, TypeError) as error:
    print('SSH profile 安全预检拒绝：' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

access_profile_get() { _access_profile_policy get "$1"; }
access_profile_list() { _access_profile_policy list; }
access_profile_preflight() {
  local user=$1 mode=$2
  _access_profile_modules "$mode" || return 1
  sshd_test >/dev/null || { log_err "现有 SSH 配置未通过 sshd -t"; return 1; }
  _access_profile_policy check "$user" "$mode"
}
access_profile_track() {
  local paths path
  paths=$(_access_profile_policy paths "$1") || return 1
  while IFS= read -r path; do change_track "$path" || return 1; done <<<"$paths"
}
access_profile_apply() { _access_profile_policy apply "$1" "$2" "${3:-}" "${4:-}" "${5:-}"; }
access_profile_disable_root() { _access_profile_policy disable-root "$1" key_password_totp; }
access_profile_verify() { _access_profile_policy verify "$1" "$2" "${3:-}" "${4:-}"; }

access_root_policy() { _access_profile_policy root-policy; }
access_root_preflight() {
  sshd_test >/dev/null || { log_err "现有 SSH 配置未通过 sshd -t"; return 1; }
  _access_profile_policy root-check
}
access_root_track() { change_track "$SSHD_CONFIG" && change_track "$(access_profile_state)"; }
access_root_apply() { _access_profile_policy root-apply; }

access_profile_expect() { # 真实 sshd -T -C 验收，不允许退回全局显示结果
  local user=$1 mode=$2 key=${3:-} method password=no pubkey=no kbd=no addr eff actual setting expected
  local connection=${SSH_CONNECTION:-}
  case $mode in
    password) method=password; password=yes ;;
    key) method=publickey; pubkey=yes ;;
    password_totp) method=keyboard-interactive:pam; kbd=yes ;;
    key_totp|key_password_totp) method=publickey,keyboard-interactive:pam; pubkey=yes; kbd=yes ;;
    *) return 1 ;;
  esac
  sshd_test >/dev/null || return 1
  for addr in "${connection%% *}" 203.0.113.1 2001:db8::1; do
    [[ -n $addr ]] || continue
    eff=$(sshd_eff_for "$user" "$addr") || { log_err "无法按 $user 的真实 SSH 上下文验收"; return 1; }
    while read -r setting expected; do
      actual=$(awk -v k="$setting" '$1 == k { $1=""; sub(/^ /, ""); print }' <<<"$eff")
      [[ $actual == "$expected" ]] || { log_err "$user 的 $setting 为 ${actual:-空}，期望 $expected"; return 1; }
    done <<EOF
authenticationmethods $method
passwordauthentication $password
pubkeyauthentication $pubkey
kbdinteractiveauthentication $kbd
permitemptypasswords no
usepam yes
EOF
    if [[ $pubkey == yes ]]; then
      actual=$(awk '$1 == "authorizedkeysfile" { $1=""; sub(/^ /, ""); print }' <<<"$eff")
      [[ $actual == "$key" ]] || { log_err "$user 的授权公钥路径不符"; return 1; }
    fi
  done
}
