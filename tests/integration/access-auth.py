#!/usr/bin/env python3
import argparse
import base64
import codecs
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import hmac
import json
import logging
import os
from pathlib import Path
import re
import secrets
import socket
import struct
import subprocess
import sys
import time

import paramiko


class IntegrationFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise IntegrationFailure(message)


@contextmanager
def report_step(label):
    try:
        yield
    except IntegrationFailure:
        raise
    except Exception as error:
        # Paramiko exceptions and PTY output need not be safe to print verbatim.
        raise IntegrationFailure(f"{label}: {type(error).__name__}") from None


def quiet_run(arguments, input_text=None):
    result = subprocess.run(
        arguments,
        input=input_text,
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    require(result.returncode == 0, "fixture command failed")


def write_private(path, content, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)


def fixture(arguments):
    work = Path(arguments.work)
    credentials = {
        "user": "vhmaccess",
        "other": "vhmlegacy",
        "key_user": "vhmkey",
        "accounts": {
            name: {
                "password": secrets.token_urlsafe(24),
                "seed": base64.b32encode(secrets.token_bytes(20)).decode("ascii"),
            }
            for name in ("root", "vhmaccess", "vhmlegacy", "vhmkey")
        },
        "port": 2222,
        "work": str(work),
    }
    quiet_run(
        ["chpasswd"],
        "".join(
            name + ":" + account["password"] + "\n"
            for name, account in credentials["accounts"].items()
        ),
    )
    keys = Path(arguments.key_file).parent
    seed_directory = Path(arguments.seed_file).parent.parent
    for name in ("root", "managed", "keyonly", "wrong"):
        key = paramiko.RSAKey.generate(2048)
        private_file = work / f"{name}.key"
        key.write_private_key_file(str(private_file))
        private_file.chmod(0o600)
        public_key = f"{key.get_name()} {key.get_base64()}\n"
        if name == "root":
            root_keys = Path("/root/.ssh")
            root_keys.mkdir(mode=0o700, exist_ok=True)
            root_keys.chmod(0o700)
            write_private(root_keys / "authorized_keys", public_key)
            write_private(keys / "root", public_key, mode=0o644)
        elif name == "managed":
            write_private(arguments.key_file, public_key, mode=0o644)
        elif name == "keyonly":
            write_private(keys / credentials["key_user"], public_key, mode=0o644)
    for name in ("root", credentials["user"]):
        seed_file = seed_directory / name / "totp"
        seed_file.parent.mkdir(parents=True, exist_ok=True)
        seed_file.parent.chmod(0o700)
        write_private(
            seed_file,
            credentials["accounts"][name]["seed"] + '\n" TOTP_AUTH\n" WINDOW_SIZE 3\n',
        )
    write_private(work / "fixture.json", json.dumps(credentials))


def totp(credentials, username, token_mode="correct"):
    def calculate(account, step):
        digest = hmac.new(
            base64.b32decode(credentials["accounts"][account]["seed"]),
            struct.pack(">Q", step), hashlib.sha1,
        ).digest()
        offset = digest[-1] & 15
        return (struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF) % 1000000

    step = int(time.time()) // 30
    number = calculate(username, step)
    valid_codes = {calculate(username, step + offset) for offset in range(-3, 4)}
    if token_mode == "wrong":
        while number in valid_codes:
            number = (number + 1) % 1000000
    elif token_mode == "foreign":
        other = credentials["user"] if username == "root" else "root"
        candidates = [calculate(other, step + offset) for offset in (0, -1, 1)]
        number = next((value for value in candidates if value not in valid_codes), None)
        require(number is not None, "could not isolate account-specific TOTP codes")
    return f"{number:06d}"


def connect(credentials, username, method):
    with report_step(f"SSH TCP connection for {username} ({method})"):
        transport = paramiko.Transport(
            socket.create_connection(("127.0.0.1", credentials["port"]), timeout=10)
        )
    try:
        with report_step(f"SSH handshake for {username} ({method})"):
            transport.banner_timeout = 10
            transport.auth_timeout = 10
            transport.start_client(timeout=10)
            host_line = (Path(credentials["work"]) / "hostkey.pub").read_text().split()
            expected_host = paramiko.Ed25519Key(data=base64.b64decode(host_line[1]))
            require(transport.get_remote_server_key() == expected_host, "unexpected SSH host key")
        return transport
    except BaseException:
        transport.close()
        raise


def execute_id(transport, username, method):
    label = f"SSH session for {username} ({method})"
    with report_step(f"{label}, open channel"):
        channel = transport.open_session(timeout=10)
    try:
        with report_step(f"{label}, execute command"):
            channel.exec_command("/usr/bin/id -u")
            require(channel.recv_exit_status() == 0, "authenticated command failed")
            return channel.recv(1024).decode().strip()
    finally:
        with report_step(f"{label}, close channel"):
            channel.close()


def legacy_login(credentials, username, expected, password=False):
    method = "publickey" if username == "root" and not password else "password"
    transport = connect(credentials, username, method)
    success = False
    try:
        try:
            if username == "root" and not password:
                key = paramiko.RSAKey.from_private_key_file(
                    str(Path(credentials["work"]) / "root.key")
                )
                transport.auth_publickey(username, key)
            else:
                secret = credentials["accounts"][username]["password"]
                transport.auth_password(username, secret, fallback=False)
            success = transport.is_authenticated()
        except paramiko.AuthenticationException:
            success = False
        except Exception as error:
            raise IntegrationFailure(f"SSH legacy authentication for {username} ({method}): {type(error).__name__}") from None
        require(success == expected, f"unexpected legacy SSH result for {username} using {method}")
        if success:
            result = execute_id(transport, username, method)
            require((result == "0") == (username == "root"), "unexpected legacy account")
    finally:
        transport.close()


def profile_login(credentials, username, mode, key_mode=None, password_mode="correct", token_mode="correct"):
    transport = connect(credentials, username, mode)
    prompts_seen = {"password": 0, "token": 0}
    password = credentials["accounts"][username]["password"]
    password = password if password_mode == "correct" else "" if password_mode == "missing" else password + "!"
    if key_mode is None:
        key_mode = "root" if username == "root" else "keyonly" if username == credentials["key_user"] else "managed"

    def respond(_title, _instructions, prompts):
        answers = []
        for prompt, echo in prompts:
            require(not echo, "authentication requested an echoed secret")
            if "verification" in prompt.lower() or "code" in prompt.lower():
                prompts_seen["token"] += 1
                answers.append("" if token_mode == "missing" else totp(credentials, username, token_mode))
            elif "password" in prompt.lower():
                prompts_seen["password"] += 1
                answers.append(password)
            else:
                raise IntegrationFailure("unexpected authentication challenge")
        return answers

    try:
        if mode.startswith("key") and key_mode != "missing":
            key = paramiko.RSAKey.from_private_key_file(
                str(Path(credentials["work"]) / f"{key_mode}.key")
            )
            transport.auth_publickey(username, key)
            if mode != "key":
                require(not transport.is_authenticated(), "SSH accepted a public key alone")
        if mode == "password":
            transport.auth_password(username, password, fallback=False)
        elif mode != "key":
            transport.auth_interactive(username, respond)
    except paramiko.AuthenticationException:
        transport.close()
        return None, prompts_seen
    except IntegrationFailure:
        transport.close()
        raise
    except Exception as error:
        transport.close()
        raise IntegrationFailure(f"SSH profile authentication for {username} ({mode}): {type(error).__name__}") from None
    except BaseException:
        transport.close()
        raise
    if not transport.is_authenticated():
        transport.close()
        return None, prompts_seen
    return transport, prompts_seen


def positive_login(credentials):
    transport, prompts = profile_login(credentials, credentials["user"], "key_password_totp")
    require(transport is not None, "three-factor SSH login was rejected")
    require(prompts["password"] > 0 and prompts["token"] > 0, "SSH skipped a required challenge")
    require(execute_id(transport, credentials["user"], "key_password_totp") != "0", "managed account unexpectedly is root")
    return transport


def wait_match(channel, pattern, label, timeout=15, *, completed=None):
    output = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if channel.recv_ready():
            output = (output + channel.recv(4096))[-8192:]
            if completed is not None and (exit_match := completed.search(output)) is not None:
                raise IntegrationFailure(f"interactive command exited with status {int(exit_match.group(1))} before {label}")
            match = pattern.search(output)
            if match is not None:
                return match
        elif channel.closed:
            break
        time.sleep(0.05)
    raise IntegrationFailure(f"interactive shell did not reach {label}")


def wait_marker(channel, marker, label, *, completed=None):
    wait_match(channel, re.compile(re.escape(marker.encode("utf-8"))), label, completed=completed)


@dataclass(frozen=True)
class SudoResult:
    status: int | None
    passwords: int
    tokens: int
    ran_as_root: bool
    hints: dict

    @property
    def both_factors(self):
        return self.passwords > 0 and self.tokens > 0

    def detail(self):
        fields = {"exit": self.status, "password_prompts": self.passwords, "token_prompts": self.tokens, **self.hints}
        return " ".join(f"{name}={value}" for name, value in fields.items())


def sudo_result(status, prompts, output):
    # Never return the transcript or an input value. Emit only counts and fixed diagnostic flags.
    lower = output.casefold()
    hints = {
        "pam_auth_error": "pam authentication" in lower or "authentication failure" in lower,
        "incorrect_password": "incorrect password" in lower or "sorry, try again" in lower,
        "missing_tty": "a terminal is required" in lower or "no tty" in lower,
        "no_new_privileges": "no new privileges" in lower or "no_new_privs" in lower,
        "setuid_error": "setuid" in lower or "effective uid is not 0" in lower,
        "account_error": "pam account management" in lower or "account validation" in lower,
        "sudo_denied": "not in the sudoers file" in lower or "not allowed to run sudo" in lower or "not allowed to execute" in lower,
        "old_session": "请关闭连接复用，建立本阶段开始后的新 SSH 连接" in output,
        "unknown_session": "无法确认来自该用户的新 SSH 会话" in output,
        "wrong_sudo_context": "必须在新 SSH 会话中由" in output or "请直接执行向导给出的 sudo vhm access-verify" in output,
    }
    return SudoResult(status, prompts["password"], prompts["token"], bool(re.search(r"(?:^|[\r\n])0[\r\n]", output)), hints)


SUDO_CHALLENGE = re.compile(
    r"(?P<token>\b(?:verification|authentication|one[- ]time)[ \t]+code:)"
    r"|(?P<password>\[sudo\][ \t]+password[ \t]+for[ \t]+[^:\r\n]+:"
    r"|(?:^|[\r\n])[ \t]*(?:[^:\r\n]+'s[ \t]+)?Password:)",
    re.IGNORECASE,
)


def sudo_command(channel, credentials, password_mode="correct", token_mode="correct", login=False, noninteractive=False, username=None, command="/usr/bin/id -u", invalidate=False):
    username = username or credentials["user"]
    arguments = "-n" if noninteractive else ""
    if login:
        arguments += " -i"
    if invalidate:
        arguments += " -k"
    channel.sendall(
        f"sudo {arguments} -- {command}; printf '\\nVHM_SUDO_DONE:%s\\n' \"$?\"\n"
    )
    pending = ""
    output = ""
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    prompts = {"password": 0, "token": 0}
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if not channel.recv_ready():
            if channel.closed:
                raise IntegrationFailure("sudo shell closed unexpectedly: " + sudo_result(None, prompts, output).detail())
            time.sleep(0.05)
            continue
        received = decoder.decode(channel.recv(4096))
        pending += received
        output += received
        result = re.search(r"VHM_SUDO_DONE:([0-9]+)[\r\n]", pending)
        if result:
            return sudo_result(int(result.group(1)), prompts, output)
        while True:
            challenge = SUDO_CHALLENGE.search(pending)
            if challenge is None:
                break
            pending = pending[challenge.end() :]
            require(not noninteractive, "noninteractive sudo asked for a secret")
            if challenge.lastgroup == "token":
                prompts["token"] += 1
                value = "" if token_mode == "missing" else totp(credentials, username, token_mode)
            else:
                prompts["password"] += 1
                password = credentials["accounts"][username]["password"]
                value = (
                    password if password_mode == "correct"
                    else "" if password_mode == "missing" else password + "!"
                )
            require(sum(prompts.values()) <= 12, "sudo repeated too many challenges")
            channel.sendall(value + "\n")
    raise IntegrationFailure("sudo conversation timed out: " + sudo_result(None, prompts, output).detail())


@contextmanager
def sudo_shell(transport):
    channel = transport.open_session(timeout=10)
    try:
        channel.get_pty(term="dumb", width=120, height=25)
        channel.exec_command("exec /bin/bash --noprofile --norc")
        channel.sendall("unset HISTFILE; export LC_ALL=C; PS1=''; stty -echo; printf '\\nVHM_SHELL_READY\\n'\n")
        wait_marker(channel, "\r\nVHM_SHELL_READY\r\n", "SSH test shell readiness")
        yield channel
    finally:
        channel.close()


def sudo_checks(credentials, transport):
    with sudo_shell(transport) as channel:
        for login in (False, False, True):
            result = sudo_command(channel, credentials, login=login)
            require(result.status == 0 and result.ran_as_root, "sudo did not run as root: " + result.detail())
            require(result.both_factors, "sudo skipped reauthentication: " + result.detail())
        result = sudo_command(channel, credentials, noninteractive=True)
        require(result.status != 0, "sudo reused cached or passwordless authorization: " + result.detail())
        for password_mode, token_mode in (
            ("wrong", "correct"), ("correct", "wrong"),
            ("missing", "correct"), ("correct", "missing"),
        ):
            result = sudo_command(channel, credentials, password_mode, token_mode)
            require(result.status != 0, "sudo accepted an incomplete or incorrect factor: " + result.detail())


def original_sudo_check(credentials, username):
    transport, _prompts = profile_login(credentials, username, "password")
    require(transport is not None, "unmanaged password SSH login was rejected")
    try:
        with sudo_shell(transport) as channel:
            channel.sendall("sudo -k; printf '\\nVHM_SUDO_RESET\\n'\n")
            wait_marker(channel, "\r\nVHM_SUDO_RESET\r\n", "sudo cache reset")
            result = sudo_command(channel, credentials, username=username)
            require(result.status == 0 and result.ran_as_root, "unmanaged sudo did not run as root: " + result.detail())
            require(result.passwords > 0 and result.tokens == 0, "sudo altered another administrator's authentication: " + result.detail())
    finally:
        transport.close()


def ssh_login_checks(credentials):
    command = "/usr/local/bin/vhm test-ssh-login"
    console = subprocess.run([*command.split(), "未识别"], capture_output=True, check=False, timeout=10)
    require(console.returncode == 0, "console was reported as an SSH login")

    root, _prompts = profile_login(credentials, "root", "key")
    require(root is not None, "root SSH login failed before identity check")
    try:
        channel = root.open_session(timeout=10)
        try:
            channel.exec_command(command + " root")
            require(channel.recv_exit_status() == 0, "root SSH login identity was not preserved")
        finally:
            channel.close()
    finally:
        root.close()

    username = credentials["other"]
    ordinary, _prompts = profile_login(credentials, username, "password")
    require(ordinary is not None, "ordinary SSH login failed before identity check")
    try:
        with sudo_shell(ordinary) as channel:
            result = sudo_command(channel, credentials, username=username, command=f"{command} '普通用户 {username}'")
            require(result.status == 0 and result.passwords > 0,
                    "sudo did not preserve the original SSH login identity: " + result.detail())
    finally:
        ordinary.close()


CREATE_DONE = re.compile(rb"\r\nVHM_CREATE_DONE:([0-9]+)\r\n")
USER_TYPE_PROMPT = "选择要配置的用户类型: "
USERNAME_PROMPT = "普通用户名（不存在时可选择创建，回车返回）: "
CONFIRM_PROMPT = "输入 yes 继续（其他输入均取消）: "
USER_MENU_PROMPT = "请选择："


def select_ordinary_user(channel, username, label, completed):
    wait_marker(channel, USER_TYPE_PROMPT, f"{label}: user type selection", completed=completed)
    channel.sendall("2\n")
    wait_marker(channel, USERNAME_PROMPT, f"{label}: username entry", completed=completed)
    channel.sendall(username + "\n")


def create_user_checks(credentials):
    from pwd import getpwnam

    username = "vhmcreated"
    password = secrets.token_urlsafe(24)
    root, _prompts = profile_login(credentials, "root", "key")
    require(root is not None, "root SSH login failed before account creation")
    try:
        with sudo_shell(root) as channel:
            channel.sendall("/usr/local/bin/vhm test-create-user; printf '\\nVHM_CREATE_DONE:%s\\n' \"$?\"\n")
            select_ordinary_user(channel, username, "create user", CREATE_DONE)
            wait_marker(channel, CONFIRM_PROMPT, "account creation confirmation", completed=CREATE_DONE)
            channel.sendall("yes\n")
            wait_marker(channel, "New password:", "new account password entry", completed=CREATE_DONE)
            channel.sendall(password + "\n")
            wait_marker(channel, "Retype new password:", "new account password confirmation", completed=CREATE_DONE)
            channel.sendall(password + "\n")
            wait_marker(channel, USER_MENU_PROMPT, "created account menu", completed=CREATE_DONE)
            channel.sendall("0\n")
            status = int(wait_match(channel, CREATE_DONE, "account creation result").group(1))
            require(status == 0, f"account creation command exited with status {status}")
    finally:
        root.close()

    account = getpwnam(username)
    home = Path(account.pw_dir)
    require(1000 <= account.pw_uid < 65534 and account.pw_shell == "/bin/bash", "created account is not a normal login user")
    require(home == Path("/home") / username and home.is_dir() and not home.is_symlink() and home.stat().st_uid == account.pw_uid,
            "created account does not own its home directory")
    groups = subprocess.run(["id", "-Gn", "--", username], capture_output=True, text=True, check=False, timeout=10)
    require(groups.returncode == 0 and groups.stdout.split() == [username], "created account has unexpected group membership")

    credentials["accounts"][username] = {"password": password}
    ordinary, _prompts = profile_login(credentials, username, "password")
    require(ordinary is not None, "created account could not log in with its configured password")
    try:
        require(execute_id(ordinary, username, "password") == str(account.pw_uid), "created account logged in with an unexpected UID")
        with sudo_shell(ordinary) as channel:
            result = sudo_command(channel, credentials, username=username)
            require(result.status != 0 and result.hints["sudo_denied"], "created account was not denied sudo authorization: " + result.detail())
    finally:
        ordinary.close()

    local_admin_checks(credentials, username)


MENU_DONE = re.compile(rb"\r\nVHM_MENU_DONE:([0-9]+)\r\n")
ROOT_PHASE = re.compile(
    rb"sudo -k /usr/local/bin/vhm access-verify ([0-9]{8}-[0-9]{6}-[0-9]+) (login|final)\r?\n.*?"
    + re.escape("新窗口验证完成后输入 yes（其他输入回滚）: ".encode("utf-8")),
    re.DOTALL,
)


def menu_action(channel, command, username, action):
    label = {7: "sudo grant", 8: "root SSH switch"}[action]
    channel.sendall(f"{command}; printf '\\nVHM_MENU_DONE:%s\\n' \"$?\"\n")
    select_ordinary_user(channel, username, label, MENU_DONE)
    wait_marker(channel, USER_MENU_PROMPT, f"{label}: selected user menu", completed=MENU_DONE)
    channel.sendall(f"{action}\n")
    wait_marker(channel, CONFIRM_PROMPT, f"{label}: confirmation", completed=MENU_DONE)


def menu_done(channel, label, timeout=15):
    return int(wait_match(channel, MENU_DONE, label, timeout).group(1))


@contextmanager
def password_shell(credentials, username):
    transport, _prompts = profile_login(credentials, username, "password")
    require(transport is not None, "ordinary SSH password login was rejected")
    try:
        with sudo_shell(transport) as channel:
            yield channel
    finally:
        transport.close()


def pam_snapshot():
    return {path.name: path.read_bytes() for path in Path("/etc/pam.d").iterdir() if path.is_file()}


def local_admin_checks(credentials, username):
    pam = pam_snapshot()
    ssh_config = Path("/etc/ssh/sshd_config")
    original_ssh = ssh_config.read_bytes()
    grant = Path("/etc/sudoers.d") / f"90-vhm-admin-{username}"
    require(not grant.exists(), "sudo authorization existed before [7]")

    root, _prompts = profile_login(credentials, "root", "key")
    require(root is not None, "root SSH login failed before administrator workflows")
    try:
        with sudo_shell(root) as channel:
            for answer in ("no", "yes"):
                menu_action(channel, "/usr/local/bin/vhm test-create-user", username, 7)
                require(not grant.exists(), "sudo authorization was written before confirmation")
                channel.sendall(answer + "\n")
                status = menu_done(channel, "sudo grant result")
                if answer == "no":
                    require(not grant.exists(), "cancelled sudo grant still wrote authorization")
                else:
                    require(status == 0 and grant.is_file(), "confirmed sudo grant did not write authorization")

            info = grant.stat()
            require((info.st_uid, info.st_gid, info.st_mode & 0o777) == (0, 0, 0o440), "sudo grant is not root-owned 0440")
            quiet_run(["visudo", "--check"])
            groups = subprocess.check_output(["id", "-Gn", "--", username], text=True, timeout=10).split()
            require(groups == [username], "sudo grant changed account groups")
            require(pam_snapshot() == pam and ssh_config.read_bytes() == original_ssh, "sudo grant changed PAM or SSH")
            with password_shell(credentials, username) as ordinary:
                refused = sudo_command(ordinary, credentials, username=username, noninteractive=True, invalidate=True)
                require(refused.status != 0, "new sudo authorization did not require a password")
                result = sudo_command(ordinary, credentials, username=username, invalidate=True)
                require(result.status == 0 and result.ran_as_root and result.passwords > 0 and result.tokens == 0,
                        "new authorization did not use existing sudo password policy: " + result.detail())
            print("PASS access-auth sudo-grant")

            root_switch_checks(credentials, channel, username, ssh_config, original_ssh, grant)
    finally:
        root.close()


def root_phase(channel, phase):
    match = wait_match(channel, ROOT_PHASE, f"root SSH switch {phase} prompt", timeout=20, completed=MENU_DONE)
    require(match.group(2).decode("ascii") == phase, "root SSH switch requested an unexpected verification phase")
    return match.group(1).decode("ascii")


def root_switch_verify(credentials, username, record, phase):
    marker = record / f"access-verified-{phase}"
    require(not marker.exists(), "root SSH verification was recorded before the new login")
    time.sleep(0.05)
    with password_shell(credentials, username) as ordinary:
        command = f"/usr/local/bin/vhm access-verify {record.name} {phase}"
        result = sudo_command(ordinary, credentials, username=username, command=command, invalidate=True)
        require(result.status == 0 and result.passwords > 0 and result.tokens == 0 and marker.is_file(),
                f"root SSH switch {phase} failed real sudo verification: " + result.detail())


def root_switch_checks(credentials, control, username, ssh_config, original_ssh, grant):
    changes = Path(credentials["work"]) / "state" / "changes"
    original_pam = pam_snapshot()
    original_grant = grant.read_bytes()
    for scenario, seconds in (("unverified", 90), ("timeout", 20), ("confirmed", 90)):
        menu_action(control, f"/usr/local/bin/vhm test-root-switch {seconds}", username, 8)
        control.sendall("yes\n")
        change = root_phase(control, "login")
        record = changes / change
        legacy_login(credentials, "root", True)
        if scenario != "unverified":
            root_switch_verify(credentials, username, record, "login")
        control.sendall("yes\n")

        if scenario != "unverified":
            require(root_phase(control, "final") == change, "root SSH switch changed transaction between phases")
            require(pam_snapshot() == original_pam and grant.read_bytes() == original_grant,
                    "root SSH switch changed PAM or sudo policy during the transition")
            legacy_login(credentials, "root", False)
            legacy_login(credentials, "root", False, password=True)
            if scenario == "confirmed":
                root_switch_verify(credentials, username, record, "final")
                control.sendall("yes\n")

        status = menu_done(control, f"root SSH switch {scenario} result", timeout=seconds + 15)
        if scenario == "confirmed":
            require(status == 0 and (record / "status").read_text().strip() == "confirmed",
                    "root SSH switch was not saved after both verifications")
            legacy_login(credentials, "root", False)
            control.sendall(f"/usr/local/bin/vhm test-root-rollback {change}; printf '\\nVHM_MENU_DONE:%s\\n' \"$?\"\n")
            require(menu_done(control, "root SSH switch cleanup") == 0, "confirmed root SSH switch could not be rolled back")
        require((record / "status").read_text().strip() == "rolled_back" and ssh_config.read_bytes() == original_ssh,
                f"root SSH switch {scenario} did not restore configuration")
        require(pam_snapshot() == original_pam and grant.read_bytes() == original_grant,
                "root SSH rollback changed PAM or sudo policy")
        legacy_login(credentials, "root", True)
        print(f"PASS access-auth root-switch-{scenario}")


def boot_ticks():
    with Path("/proc/uptime").open() as stream:
        return int(float(stream.readline().split()[0]) * os.sysconf("SC_CLK_TCK"))


def verify_checks(credentials, change, phase):
    require(change and re.fullmatch(r"[0-9]{8}-[0-9]{6}-[0-9]+", change), "invalid change fixture")
    record = Path(credentials["work"]) / "state" / "changes" / change
    marker = record / f"access-verified-{phase}"
    command = f"/usr/local/bin/vhm access-verify {change} {phase}"
    require(not marker.exists(), "verification marker already exists")

    if phase == "login":
        old = positive_login(credentials)
        try:
            with sudo_shell(old) as channel:
                # The server session is already running when we set the cutoff.
                cutoff = boot_ticks()
                write_private(record / "access-cutoff", str(cutoff) + "\n")
                result = sudo_command(channel, credentials, command=command)
                require(result.both_factors, "old session skipped sudo authentication: " + result.detail())
                require(result.status != 0 and result.hints["old_session"] and not marker.exists(),
                        "old SSH session was not rejected by the freshness check: " + result.detail())
        finally:
            old.close()
    else:
        cutoff = boot_ticks()
        write_private(record / "access-cutoff", str(cutoff) + "\n")
    time.sleep(0.05)

    fresh = positive_login(credentials)
    try:
        with sudo_shell(fresh) as channel:
            result = sudo_command(channel, credentials, command=command)
            require(result.both_factors, "verification skipped either sudo factor: " + result.detail())
            require(result.status == 0 and marker.is_file(), "fresh SSH session failed to verify the change: " + result.detail())
    finally:
        fresh.close()

    content = marker.read_text().strip()
    require(re.fullmatch(r"[0-9]+:[0-9]+", content), "verification marker lacks an SSH process and timestamp")
    require(int(content.split(":", 1)[1]) > cutoff, "verification marker refers to an old session")
    info = marker.stat()
    require(info.st_uid == 0 and info.st_mode & 0o777 == 0o600, "verification marker is not root-private")


def expect_profile(credentials, username, mode, **options):
    transport, prompts = profile_login(credentials, username, mode, **options)
    require(transport is not None, f"SSH profile was rejected for {username} using {mode}")
    try:
        require((execute_id(transport, username, mode) == "0") == (username == "root"), "profile authenticated an unexpected account")
        password_required = mode in ("password_totp", "key_password_totp")
        require((prompts["password"] > 0) == password_required, "profile used another account's password route")
        require((prompts["token"] > 0) == mode.endswith("_totp"), "profile used another account's TOTP route")
    finally:
        transport.close()


def reject_profile(credentials, username, mode, **options):
    transport, _prompts = profile_login(credentials, username, mode, **options)
    if transport is not None:
        transport.close()
        case = ",".join(name + "=" + value for name, value in sorted(options.items()))
        raise IntegrationFailure(f"SSH accepted a forbidden login for {username} using {mode} ({case})")


def profiles_check(credentials, updated=False):
    user = credentials["user"]
    key_user = credentials["key_user"]
    expect_profile(credentials, "root", "key_totp")
    expect_profile(credentials, key_user, "key")
    expect_profile(credentials, user, "password" if updated else "password_totp")
    legacy_login(credentials, credentials["other"], True)
    for options in (
        {"key_mode": "missing"}, {"key_mode": "wrong"},
        {"token_mode": "missing"}, {"token_mode": "wrong"}, {"token_mode": "foreign"},
    ):
        reject_profile(credentials, "root", "key_totp", **options)
    reject_profile(credentials, "root", "password")
    reject_profile(credentials, key_user, "key", key_mode="wrong")
    reject_profile(credentials, key_user, "key", key_mode="missing")
    reject_profile(credentials, key_user, "password")
    if updated:
        reject_profile(credentials, user, "password", password_mode="wrong")
        reject_profile(credentials, user, "password", password_mode="missing")
    else:
        reject_profile(credentials, user, "password")
        for options in (
            {"password_mode": "missing"}, {"password_mode": "wrong"},
            {"token_mode": "missing"}, {"token_mode": "wrong"}, {"token_mode": "foreign"},
        ):
            reject_profile(credentials, user, "password_totp", **options)


def check(arguments):
    credentials = json.loads((Path(arguments.work) / "fixture.json").read_text())
    if arguments.stage in ("baseline", "rollback"):
        legacy_login(credentials, "root", True)
        legacy_login(credentials, "root", True, password=True)
        legacy_login(credentials, credentials["other"], True)
        original_sudo_check(credentials, credentials["user"])
    elif arguments.stage == "login-identity":
        with report_step(arguments.stage):
            ssh_login_checks(credentials)
    elif arguments.stage == "create-user":
        with report_step(arguments.stage):
            create_user_checks(credentials)
    elif arguments.stage == "stage-one":
        legacy_login(credentials, "root", True)
        legacy_login(credentials, "root", True, password=True)
        legacy_login(credentials, credentials["other"], True)
        transport = positive_login(credentials)
        transport.close()
        for key_mode, password_mode, token_mode in (
            ("missing", "correct", "correct"), ("wrong", "correct", "correct"),
            ("managed", "missing", "correct"), ("managed", "wrong", "correct"),
            ("managed", "correct", "missing"), ("managed", "correct", "wrong"),
        ):
            reject_profile(credentials, credentials["user"], "key_password_totp", key_mode=key_mode,
                           password_mode=password_mode, token_mode=token_mode)
    elif arguments.stage == "stage-two":
        legacy_login(credentials, "root", False)
        legacy_login(credentials, "root", False, password=True)
        legacy_login(credentials, credentials["other"], True)
        transport = positive_login(credentials)
        try:
            with report_step("managed sudo conversation"):
                sudo_checks(credentials, transport)
        finally:
            transport.close()
        with report_step("unmanaged sudo conversation"):
            original_sudo_check(credentials, credentials["other"])
    elif arguments.stage in ("profiles", "profiles-updated"):
        profiles_check(credentials, updated=arguments.stage == "profiles-updated")
    elif arguments.stage in ("verify-login", "verify-final"):
        with report_step(arguments.stage):
            verify_checks(credentials, arguments.change, arguments.stage.removeprefix("verify-"))
    print(f"PASS access-auth {arguments.stage}")


def main():
    logging.getLogger("paramiko").setLevel(logging.CRITICAL)
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "stage",
        choices=("fixture", "baseline", "login-identity", "create-user", "stage-one", "stage-two", "verify-login", "verify-final", "rollback", "profiles", "profiles-updated"),
    )
    parser.add_argument("work")
    parser.add_argument("--key-file")
    parser.add_argument("--seed-file")
    parser.add_argument("--change")
    arguments = parser.parse_args()
    require(os.geteuid() == 0 and Path("/.dockerenv").exists() and os.environ.get("VHM_ACCESS_INTEGRATION") == "1",
            "run only in a disposable Docker container with VHM_ACCESS_INTEGRATION=1")
    if arguments.stage == "fixture":
        fixture(arguments)
    else:
        check(arguments)


if __name__ == "__main__":
    try:
        main()
    except IntegrationFailure as error:
        print(f"FAIL access-auth: {error}", file=sys.stderr)
        sys.exit(1)
    except BaseException as error:
        print(f"FAIL access-auth: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
