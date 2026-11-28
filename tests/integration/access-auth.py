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


def wait_marker(channel, marker, timeout=15):
    output = ""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if channel.recv_ready():
            output += channel.recv(4096).decode("utf-8", errors="replace")
            if marker in output:
                return
        elif channel.closed:
            break
        time.sleep(0.05)
    raise IntegrationFailure("interactive shell did not become ready")


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


def sudo_command(channel, credentials, password_mode="correct", token_mode="correct", login=False, noninteractive=False, username=None, command="/usr/bin/id -u"):
    username = username or credentials["user"]
    arguments = "-n" if noninteractive else ""
    if login:
        arguments += " -i"
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
        wait_marker(channel, "\r\nVHM_SHELL_READY\r\n")
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
            wait_marker(channel, "\r\nVHM_SUDO_RESET\r\n")
            result = sudo_command(channel, credentials, username=username)
            require(result.status == 0 and result.ran_as_root, "unmanaged sudo did not run as root: " + result.detail())
            require(result.passwords > 0 and result.tokens == 0, "sudo altered another administrator's authentication: " + result.detail())
    finally:
        transport.close()


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
        choices=("fixture", "baseline", "stage-one", "stage-two", "verify-login", "verify-final", "rollback", "profiles", "profiles-updated"),
    )
    parser.add_argument("work")
    parser.add_argument("--key-file")
    parser.add_argument("--seed-file")
    parser.add_argument("--change")
    arguments = parser.parse_args()
    require(os.geteuid() == 0 and Path("/.dockerenv").exists(), "run only in a disposable Docker container")
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
