# shellcheck shell=bash
# shellcheck disable=SC2034
# 普通管理用户的 sudo 密码 + TOTP；只收紧已有管理员的认证，不添加 sudo 授权。

PAM_SUDO=${PAM_SUDO:-/etc/pam.d/sudo}
PAM_SUDO_I=${PAM_SUDO_I:-/etc/pam.d/sudo-i}
PAM_ACCESS_SUDO=${PAM_ACCESS_SUDO:-/etc/pam.d/vhm-access-sudo}
PAM_COMMON_AUTH=${PAM_COMMON_AUTH:-/etc/pam.d/common-auth}
SUDOERS_MAIN=${SUDOERS_MAIN:-/etc/sudoers}
SUDOERS_DIR=${SUDOERS_DIR:-/etc/sudoers.d}
SUDOERS_ACCESS=${SUDOERS_ACCESS:-$SUDOERS_DIR/99-vhm-access}
NSSWITCH_CONF=${NSSWITCH_CONF:-/etc/nsswitch.conf}
SUDO_CONF=${SUDO_CONF:-/etc/sudo.conf}
ACCESS_PASSWD_FILE=${ACCESS_PASSWD_FILE:-/etc/passwd}

# 单独封装属主检查，隔离测试可使用测试账号自己的临时文件；实际配置只接受 root 属主。
_access_sudo_owner_uid() { printf '0\n'; }

_access_sudo_modules() {
  local name path found
  for name in pam_unix pam_succeed_if pam_google_authenticator; do
    found=0
    for path in /lib/security/"$name.so" /usr/lib/security/"$name.so" /lib/*/security/"$name.so" /usr/lib/*/security/"$name.so"; do
      if [[ -f $path ]]; then found=1; break; fi
    done
    ((found)) || { log_err "缺少 $name.so，未修改 sudo 配置"; return 1; }
  done
}

_access_sudo_identity() { # 输出 yes/no：该本地普通用户是否属于 sudo 组
  local user=$1 entry nss_entry status groups name pw uid gid gecos home shell
  [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ && $user != root ]] || { log_err "sudo 管理用户名称不受支持"; return 1; }
  entry=$(awk -F: -v u="$user" '$1 == u { print; n++ } END { if (n != 1) exit 1 }' "$ACCESS_PASSWD_FILE") || {
    log_err "sudo 管理用户必须是已有的本地账号"; return 1;
  }
  IFS=: read -r name pw uid gid gecos home shell <<<"$entry"
  [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $uid -ge 1000 && $home == /* && $shell == /* && $shell != */nologin && $shell != */false ]] || {
    log_err "sudo 管理用户必须是 UID 不小于 1000、可登录的普通账号"; return 1;
  }
  nss_entry=$(getent passwd "$user") || { log_err "无法通过 NSS 确认 sudo 管理用户"; return 1; }
  [[ $entry == "$nss_entry" ]] || { log_err "本地账号与 NSS 账号不一致，未修改 sudo 配置"; return 1; }
  awk -F: -v u="$uid" '$3 == u { n++ } END { exit n != 1 }' "$ACCESS_PASSWD_FILE" || {
    log_err "该 UID 存在多个本地账号，需先人工整理"; return 1;
  }
  status=$(LC_ALL=C passwd -S "$user") || { log_err "无法检查管理用户的密码状态"; return 1; }
  [[ $(awk '{print $1, $2}' <<<"$status") == "$user P" ]] || { log_err "管理用户需要已有的非空、未锁定账号密码"; return 1; }
  groups=$(id -nG "$user") || return 1
  groups=${groups//$'\n'/ }
  if [[ " $groups " == *" sudo "* ]]; then printf 'yes\n'; else printf 'no\n'; fi
}

_access_sudo_policy() { # check/apply 用户 sudo组成员 yes/no [集中保存的 TOTP 文件]
  python3 - "$1" "$2" "$3" "${4:-}" "$(_access_sudo_owner_uid)" \
    "$PAM_SUDO" "$PAM_SUDO_I" "$PAM_ACCESS_SUDO" "$PAM_COMMON_AUTH" \
    "$SUDOERS_MAIN" "$SUDOERS_DIR" "$SUDOERS_ACCESS" "$NSSWITCH_CONF" "$SUDO_CONF" <<'PY'
import os
import re
import shlex
import stat
import sys
import tempfile
from pathlib import Path

(mode, user, sudo_member, secret, owner, pam_sudo, pam_sudo_i, pam_helper,
 common_auth, sudoers_main, sudoers_dir, sudoers_managed, nsswitch, sudo_conf) = sys.argv[1:]
owner = int(owner)
header = '# Managed by vaultwarden-hardening-manager; do not edit.\n'

def refuse(message):
    raise ValueError(message)

def safe_path(value):
    if (not re.fullmatch(r'/[A-Za-z0-9_./-]+', value) or '//' in value or
            any(part in ('.', '..') for part in value.split('/'))):
        refuse('不支持此配置路径，需使用无转义、无空白的绝对路径')
    return Path(value)

def checked(value, kind='file', missing=False, private=False):
    path = safe_path(str(value))
    parts = path.parts
    for index in range(1, len(parts)):
        current = Path(*parts[:index + 1])
        last = index == len(parts) - 1
        try:
            info = current.lstat()
        except FileNotFoundError:
            if last and missing:
                return path
            refuse('缺少配置文件或目录：' + str(current))
        if stat.S_ISLNK(info.st_mode):
            refuse('配置路径含符号链接：' + str(current))
        if not last or kind == 'dir':
            if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, owner):
                refuse('配置目录属主或类型不安全：' + str(current))
            # /tmp 等 root 属主的粘滞目录中，其他用户不能移动其下已有的私有目录。
            sticky_root = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
            if info.st_mode & 0o022 and not sticky_root:
                refuse('配置目录允许其他用户写入：' + str(current))
        else:
            if not stat.S_ISREG(info.st_mode) or info.st_uid != owner or info.st_mode & 0o022:
                refuse('配置文件属主、类型或权限不安全：' + str(current))
            if private and (stat.S_IMODE(info.st_mode) not in (0o400, 0o600) or info.st_nlink != 1):
                refuse('TOTP 文件必须由 root 独占，权限为 0600/0400，且不能有硬链接')
    return path

def text(path):
    try:
        return path.read_text(encoding='utf-8')
    except (OSError, UnicodeError):
        refuse('无法读取配置：' + str(path))

def active_lines(content):
    for line in content.splitlines():
        stripped = line.split('#', 1)[0].strip()
        if stripped:
            yield stripped

def helper_content(secret_file):
    return (header + '# user: ' + user + '\n'
            'auth substack common-auth\n'
            'auth [success=1 auth_err=ignore default=die] pam_succeed_if.so user != ' + user + '\n'
            'auth required pam_google_authenticator.so user=root secret=' + secret_file + '\n')

def managed_content():
    return (header + '# user: ' + user + '\n'
            'Defaults:' + user + ' authenticate, !rootpw, !targetpw, !runaspw, timestamp_timeout=0\n'
            'Defaults:' + user + ' pam_service="sudo", pam_login_service="sudo-i", listpw=always, verifypw=always\n')

def check_common_auth():
    lines = [' '.join(line.split()) for line in active_lines(text(checked(common_auth)))]
    unix = r'auth \[success=1 default=ignore\] pam_unix\.so(?: (?:nullok|try_first_pass))*'
    if (len(lines) not in (3, 4) or not re.fullmatch(unix, lines[0]) or
            lines[1:3] != ['auth requisite pam_deny.so', 'auth required pam_permit.so'] or
            (len(lines) == 4 and lines[3] != 'auth optional pam_cap.so')):
        refuse('common-auth 不是受支持的 Debian/Ubuntu 本地密码认证栈；请先人工审核，未修改 PAM')

def render_service(value, login=False):
    path = checked(value, missing=login)
    helper_name = Path(pam_helper).name
    if not path.exists():
        return (header + 'auth substack ' + helper_name + '\n'
                'account include sudo\n' + 'session include sudo\n')
    result = []
    auth_count = 0
    for original in text(path).splitlines():
        line = original.split('#', 1)[0].strip()
        if not line:
            result.append(original)
            continue
        parts = line.split()
        if parts[0] == '@include':
            if len(parts) != 2:
                refuse('不支持的 PAM include：' + value)
            if parts[1] == 'common-auth':
                auth_count += 1
                result.append('auth substack ' + helper_name)
            elif parts[1] in ('common-account', 'common-password', 'common-session', 'common-session-noninteractive'):
                # 限定类型，避免 @include 的非认证文件意外引入另一条 auth 路径。
                category = parts[1].split('-')[1]
                result.append(category + ' include ' + parts[1])
            else:
                refuse('不支持的 PAM include：' + value)
        elif parts[0] in ('auth', '-auth'):
            source_ok = (len(parts) == 3 and parts[0] == 'auth' and parts[1] in ('include', 'substack') and
                         (parts[2] == 'common-auth' or (login and parts[2] == 'sudo') or
                          (parts[2] == helper_name and Path(pam_helper).exists())))
            if not source_ok:
                refuse('sudo PAM 中存在额外或不受支持的认证规则：' + value)
            auth_count += 1
            result.append('auth substack ' + helper_name)
        elif parts[0].lstrip('-') in ('account', 'password', 'session'):
            result.append(original)
        else:
            refuse('无法识别的 sudo PAM 配置：' + value)
    if auth_count != 1:
        refuse('sudo PAM 必须只有一条标准密码认证入口：' + value)
    return '\n'.join(result) + '\n'

def uncomment(line):
    quoted = False
    for index, char in enumerate(line):
        if char == '"':
            quoted = not quoted
        elif char == '#' and not quoted and (index + 1 == len(line) or not line[index + 1].isdigit()):
            return line[:index].strip()
    if quoted:
        refuse('sudoers 中有无法识别的引号')
    return line.strip()

def records(content):
    pending = ''
    for raw in content.splitlines():
        line = raw.rstrip()
        if line.endswith('\\'):
            # sudoers 注释与续行的词法组合容易产生歧义，不能让后面的授权被当作注释吞掉。
            if '#' in line:
                refuse('不支持 sudoers 注释中的续行，需先人工整理')
            pending += line[:-1] + ' '
            continue
        line = pending + line
        pending = ''
        # include 的 # 具有语法意义；先保留，交给 include 解析器。
        stripped = line.strip()
        if re.match(r'^(?:#|@)include(?:dir)?\s', stripped):
            yield stripped
        else:
            clean = uncomment(line)
            if clean:
                yield clean
    if pending:
        refuse('sudoers 中存在未完成的续行')

def default_items(value):
    start = 0
    quoted = False
    for index, char in enumerate(value):
        if char == '"':
            quoted = not quoted
        elif char == ',' and not quoted:
            yield value[start:index].strip()
            start = index + 1
    if quoted:
        refuse('sudoers Defaults 引号不完整')
    yield value[start:].strip()

def check_defaults(line):
    # 其他按用户、命令、主机或 Runas 的 Defaults 优先级更复杂，不能证明无旁路时拒绝。
    if not line.startswith('Defaults ') and not line.startswith('Defaults\t'):
        refuse('存在自定义作用域的 sudoers Defaults，需先人工审核')
    flags = {'env_reset', 'mail_badpass', 'use_pty', 'pwfeedback', 'insults', 'requiretty',
             'set_home', 'always_set_home', 'visiblepw', 'log_input', 'log_output', 'log_year', 'log_host',
             'fqdn', 'ignore_dot', 'umask_override', 'match_group_by_gid'}
    values = {'env_keep', 'env_delete', 'env_check', 'secure_path', 'passwd_timeout', 'passwd_tries',
              'lecture', 'lecture_file', 'badpass_message', 'passprompt', 'logfile', 'iolog_dir', 'iolog_file', 'umask'}
    for item in default_items(line.split(None, 1)[1]):
        match = re.fullmatch(r'(!?)([a-z_]+)(?:\s*([+\-]?=)\s*(.+))?', item)
        if not match:
            refuse('不支持的 sudoers Defaults 语法')
        negate, key, operator, value = match.groups()
        if key == 'authenticate' and not negate and not operator:
            continue
        if key in ('rootpw', 'targetpw', 'runaspw') and negate and not operator:
            continue
        if key == 'timestamp_timeout' and not negate and operator == '=' and value == '0':
            continue
        expected = {'pam_service': 'sudo', 'pam_login_service': 'sudo-i', 'listpw': 'always', 'verifypw': 'always'}
        if key in expected and not negate and operator == '=' and value.strip('"') == expected[key]:
            continue
        if key in flags and not operator:
            continue
        if key in values and not negate and operator in ('=', '+=', '-='):
            continue
        refuse('sudoers Defaults 可能绕过账号密码、TOTP 或每次认证要求：' + key)

def check_sudoers():
    directory = checked(sudoers_dir, kind='dir')
    managed = checked(sudoers_managed, missing=True)
    if managed.parent != directory or '.' in managed.name or managed.name.endswith('~'):
        refuse('托管 sudoers 文件必须位于 sudoers.d，文件名不能含点或以 ~ 结尾')
    if managed.exists() and text(managed) != managed_content():
        refuse('托管 sudoers 文件属于其他用户或已被修改；请先人工审核/回滚')
    seen, active = set(), set()
    managed_directory_included = False
    full_admin = False
    all_rule = re.compile(r'(?P<who>[a-z_][a-z0-9_-]*|%[a-z_][a-z0-9_-]*)\s+ALL\s*=\s*'
                          r'\(\s*ALL\s*(?::\s*ALL\s*)?\)\s*(?P<tag>PASSWD\s*:\s*)?ALL')

    def walk(value, depth=0):
        nonlocal managed_directory_included, full_admin
        if depth > 16 or len(seen) >= 128:
            refuse('sudoers include 层数或文件数过多')
        path = checked(value)
        if path in active or path in seen:
            refuse('sudoers 存在循环或重复 include')
        active.add(path)
        seen.add(path)
        if path == managed:
            active.remove(path)
            return
        for line in records(text(path)):
            include = re.fullmatch(r'[#@](include|includedir)\s+(.+)', line)
            if include:
                try:
                    args = shlex.split(include[2], comments=True)
                except ValueError:
                    refuse('不支持的 sudoers include 路径')
                if len(args) != 1:
                    refuse('不支持的 sudoers include 路径')
                if include[1] == 'include':
                    walk(args[0], depth + 1)
                else:
                    child_dir = checked(args[0], kind='dir')
                    if child_dir == directory:
                        managed_directory_included = True
                    for child in sorted(child_dir.iterdir()):
                        if '.' not in child.name and not child.name.endswith('~'):
                            walk(str(child), depth + 1)
                continue
            if '\\' in line or re.search(r'\bNOPASSWD\s*:', line, re.I):
                refuse('sudoers 存在 NOPASSWD 或无法安全识别的转义规则，需先人工整理')
            if line.startswith('Defaults'):
                check_defaults(line)
                continue
            match = all_rule.fullmatch(line)
            if not match:
                refuse('sudoers 存在别名、否定或部分命令等自定义授权；不会自动改写或扩权')
            if ((match['who'] == '%sudo' and sudo_member == 'yes') or
                    (match['who'] == user and match['tag'])):
                full_admin = True
        active.remove(path)

    walk(sudoers_main)
    if not managed_directory_included:
        refuse('sudoers 未包含指定的 sudoers.d 目录，托管策略不会生效')
    if not full_admin:
        refuse('用户尚无标准 sudo 组或明确的用户 PASSWD:ALL 管理授权；本功能不会自动授予 ALL')

def check_policy_sources():
    source = checked(nsswitch)
    for line in active_lines(text(source)):
        if re.match(r'^sudoers\s*:', line) and line.split(':', 1)[1].split() != ['files']:
            refuse('sudoers 使用了 LDAP/SSSD 等非本地策略源，无法证明每次认证要求')
    conf = checked(sudo_conf, missing=True)
    if conf.exists():
        allowed = {'Plugin sudoers_policy sudoers.so', 'Plugin sudoers_io sudoers.so', 'Plugin sudoers_audit sudoers.so'}
        if any(' '.join(line.split()) not in allowed for line in active_lines(text(conf))):
            refuse('sudo.conf 有自定义插件、插件目录或其他设置，需先人工审核')

def check_existing_helper():
    helper = checked(pam_helper, missing=True)
    if not re.fullmatch(r'[A-Za-z0-9_-]+', helper.name) or helper.name in ('sudo', 'sudo-i', 'common-auth'):
        refuse('托管 PAM 文件名称不受支持')
    if helper.parent != Path(pam_sudo).parent or Path(pam_sudo_i).parent != helper.parent or Path(common_auth).parent != helper.parent:
        refuse('sudo、sudo-i、common-auth 与托管 PAM 文件必须位于同一 PAM 目录')
    if Path(pam_sudo).name != 'sudo' or Path(pam_sudo_i).name != 'sudo-i' or Path(common_auth).name != 'common-auth':
        refuse('不支持重命名的 sudo PAM 服务')
    if helper.exists():
        content = text(helper)
        match = re.search(r'^auth required pam_google_authenticator\.so user=root secret=(/[^\n]+)$', content, re.M)
        if not match or content != helper_content(match[1]):
            refuse('托管 sudo PAM 文件属于其他用户或已被修改；请先人工审核/回滚')
        safe_path(match[1])

def check_secret():
    path = checked(secret, private=True)
    info = path.parent.stat()
    if info.st_uid != owner or stat.S_IMODE(info.st_mode) != 0o700:
        refuse('集中 TOTP 文件的直接父目录必须由 root 独占，权限为 0700')
    lines = text(path).splitlines()
    if not lines or not re.fullmatch(r'[A-Z2-7]{16,128}', lines[0]):
        refuse('集中 TOTP 文件没有有效的 Base32 密钥')

def atomic_write(value, content, permissions):
    target = checked(value, missing=True)
    descriptor, tmp = tempfile.mkstemp(prefix='.vhm-sudo-', dir=target.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            stream.write(content)
            stream.flush()
            os.fchmod(stream.fileno(), permissions)
            os.fsync(stream.fileno())
        os.replace(tmp, target)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

try:
    if mode not in ('check', 'apply', 'verify'):
        refuse('内部 sudo 操作无效')
    check_policy_sources()
    check_common_auth()
    check_existing_helper()
    sudo_content = render_service(pam_sudo)
    login_content = render_service(pam_sudo_i, login=True)
    check_sudoers()
    if mode in ('apply', 'verify'):
        check_secret()
    if mode == 'verify':
        if (not Path(pam_helper).exists() or text(Path(pam_helper)) != helper_content(secret) or
                not Path(sudoers_managed).exists() or text(Path(sudoers_managed)) != managed_content() or
                text(Path(pam_sudo)) != sudo_content or not Path(pam_sudo_i).exists() or
                text(Path(pam_sudo_i)) != login_content):
            refuse('实际 sudo/sudo-i PAM 与逐次认证 Defaults 不再是受管策略，请先恢复或回滚')
    if mode == 'apply':
        atomic_write(pam_helper, helper_content(secret), 0o644)
        atomic_write(pam_sudo, sudo_content, 0o644)
        atomic_write(pam_sudo_i, login_content, 0o644)
        atomic_write(sudoers_managed, managed_content(), 0o440)
except (ValueError, OSError) as error:
    print('sudo 安全预检拒绝：' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

access_sudo_preflight() { # 在 change_begin 前调用，不写配置
  local user=$1 command_name member version
  for command_name in python3 getent passwd id sudo visudo; do
    command -v "$command_name" >/dev/null 2>&1 || { log_err "缺少 $command_name，未修改 sudo 配置"; return 1; }
  done
  member=$(_access_sudo_identity "$user") || return 1
  _access_sudo_modules || return 1
  version=$(LC_ALL=C sudo -V) || { log_err "无法读取 sudo 编译配置"; return 1; }
  grep -Eq "^Authentication methods:[[:space:]]*'pam'[[:space:]]*$" <<<"$version" || {
    log_err "sudo 未确认使用标准 PAM 认证，未修改配置"; return 1;
  }
  [[ $(sed -n 's/^Sudoers path: //p' <<<"$version") == "$SUDOERS_MAIN" ]] || {
    log_err "sudo 的实际策略文件与预期不一致，未修改配置"; return 1;
  }
  visudo -c -f "$SUDOERS_MAIN" >/dev/null || { log_err "现有完整 sudoers 检查失败，未修改配置"; return 1; }
  _access_sudo_policy check "$user" "$member"
}

access_sudo_track() { # change_begin 后、guard_start 前调用；common-auth 与原授权规则不会改写
  local path
  for path in "$PAM_SUDO" "$PAM_SUDO_I" "$PAM_ACCESS_SUDO" "$SUDOERS_ACCESS"; do
    change_track "$path" || return 1
  done
}

access_sudo_apply() { # 必须在变更记录和自动回滚保护启用后调用
  local user=$1 secret=$2 member
  access_sudo_preflight "$user" || return 1
  member=$(_access_sudo_identity "$user") || return 1
  _access_sudo_policy apply "$user" "$member" "$secret" || return 1
  visudo -c -f "$SUDOERS_MAIN" >/dev/null || { log_err "修改后完整 sudoers 检查失败，请立即回滚"; return 1; }
}

access_sudo_verify() { # 只读核对实际受管文件、完整策略与集中秘密的所有权/权限
  local user=$1 secret=$2 member
  access_sudo_preflight "$user" || return 1
  member=$(_access_sudo_identity "$user") || return 1
  _access_sudo_policy verify "$user" "$member" "$secret"
}
