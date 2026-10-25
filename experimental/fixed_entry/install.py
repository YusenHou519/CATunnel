#!/usr/bin/env python3
"""Explicit, user-scoped fixed-entry installer, supplied over an owned SSH session."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import stat
import struct
import subprocess
import sys
import time

PAYLOAD_LIMIT = 262144
LINE_LIMIT = 4096
START_TIMEOUT = 8.0
HEX = re.compile(r"[0-9a-f]{64}\Z")
EPOCH = re.compile(r"[0-9a-f]{32}\Z")


class InstallError(Exception):
    pass


def fail(code):
    raise InstallError(code)


def directory(path, create=False):
    if create:
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        fail("directory_unsafe")
    return info


def regular(info):
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        fail("file_unsafe")


def open_file(path, flags=os.O_RDONLY):
    try:
        fd = os.open(str(path), flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError:
        fail("file_unsafe")
    try:
        regular(os.fstat(fd))
    except BaseException:
        os.close(fd)
        raise
    return fd


def read_file(path, limit):
    with os.fdopen(open_file(path), "rb") as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        fail("file_unsafe")
    return data


def read_json(path):
    try:
        value = json.loads(read_file(path, LINE_LIMIT).decode("utf-8"))
    except (ValueError, UnicodeError, RecursionError):
        fail("file_unsafe")
    if type(value) is not dict:
        fail("file_unsafe")
    return value


def write_new(path, data, owned=None):
    """Publish a complete file without replacing anything already at the target."""
    temporary = path.with_name(".stage-" + secrets.token_hex(12))
    fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    identity = os.fstat(fd)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        if owned is not None:
            owned.append((path, identity.st_dev, identity.st_ino))
        os.link(str(temporary), str(path), follow_symlinks=False)
    finally:
        with contextlib.suppress(FileNotFoundError):
            current = temporary.lstat()
            if (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino):
                temporary.unlink()


def names(path, allowed):
    if set(os.listdir(path)) - set(allowed):
        fail("installation_unknown" if path.name != "r" else "runtime_not_clean")


def initialize(target, runtime, helper, payload, manifest):
    owned = []
    try:
        for path in (target, runtime):
            path.mkdir(mode=0o700)
            info = directory(path)
            owned.append((path, info.st_dev, info.st_ino))
        write_new(helper, payload, owned)
        write_new(target / "manifest.json", json.dumps(manifest, separators=(",", ":")).encode("utf-8") + b"\n", owned)
    except BaseException:
        for path, device, inode in reversed(owned):
            with contextlib.suppress(OSError):
                info = path.lstat()
                if (info.st_dev, info.st_ino) == (device, inode):
                    path.rmdir() if stat.S_ISDIR(info.st_mode) else path.unlink()
        raise


def peer_pid(connection):
    if hasattr(socket, "SO_PEERCRED"):
        credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        pid, uid, _ = struct.unpack("3i", credentials)
        if uid != os.getuid():
            fail("helper_identity_mismatch")
        return pid
    if sys.platform == "darwin":
        # Darwin's sys/un.h defines SOL_LOCAL=0 and LOCAL_PEERPID=0x002.
        return connection.getsockopt(0, 0x002)
    fail("python_unsupported")


def helper_status(runtime, port, expected_pid=None):
    ready = read_json(runtime / "ready.json")
    pid, epoch = ready.get("pid"), ready.get("epoch")
    if (type(pid) is not int or pid <= 0 or type(ready.get("port")) is not int
            or ready["port"] != port or not isinstance(epoch, str) or not EPOCH.fullmatch(epoch)
            or (expected_pid is not None and pid != expected_pid)):
        fail("helper_identity_mismatch")
    info = (runtime / "control.sock").lstat()
    if (not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        fail("file_unsafe")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as control:
        control.settimeout(1.0)
        control.connect(str(runtime / "control.sock"))
        if peer_pid(control) != pid:
            fail("helper_identity_mismatch")
        control.sendall(b'{"op":"status"}\n')
        response = bytearray()
        while len(response) <= LINE_LIMIT and not response.endswith(b"\n"):
            chunk = control.recv(LINE_LIMIT + 1 - len(response))
            if not chunk:
                break
            response.extend(chunk)
    try:
        state = json.loads(response.decode("utf-8"))
    except (ValueError, UnicodeError, RecursionError):
        fail("helper_identity_mismatch")
    if (len(response) > LINE_LIMIT or not response.endswith(b"\n") or type(state) is not dict
            or state.get("ok") is not True or state.get("epoch") != epoch
            or type(state.get("port")) is not int or state["port"] != port
            or type(state.get("generation")) is not int or state["generation"] < 0
            or (state.get("active_generation") is not None
                and (type(state["active_generation"]) is not int or state["active_generation"] < 1))
            or "active_generation" not in state):
        fail("helper_identity_mismatch")
    if state["active_generation"] is not None:
        fail("active_entry")
    return pid


def runtime_running(runtime):
    directory(runtime)
    names(runtime, ("relay.lock", "ready.json", "control.sock"))
    lock_path = runtime / "relay.lock"
    if not os.path.lexists(lock_path):
        if os.listdir(runtime):
            fail("runtime_not_clean")
        return False
    fd = open_file(lock_path, os.O_RDWR)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        if set(os.listdir(runtime)) != {"relay.lock"}:
            fail("runtime_not_clean")
        return False
    finally:
        os.close(fd)


def port_available(port):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.bind(("127.0.0.1", port))
    except OSError:
        fail("port_in_use")


def terminate_owned(child):
    # Only the direct child handle is used; a ready/pid file never authorizes a signal.
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=2)


def start_helper(helper, runtime, port, log):
    log_fd = open_file(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
    child = None
    try:
        with os.fdopen(log_fd, "ab", buffering=0) as output:
            child = subprocess.Popen([sys.executable, "-I", str(helper), "serve", "--runtime-dir",
                                      str(runtime), "--port", str(port)],
                                     stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                     start_new_session=True, close_fds=True, cwd=str(helper.parent))
        until = time.monotonic() + START_TIMEOUT
        while time.monotonic() < until:
            if child.poll() is not None:
                fail("start_failed")
            if (os.path.lexists(runtime / "ready.json")
                    and (runtime / "ready.json").lstat().st_size > 0):
                pid = helper_status(runtime, port, child.pid)
                if not runtime_running(runtime) or child.poll() is not None:
                    fail("helper_identity_mismatch")
                return pid
            time.sleep(0.04)
        fail("start_failed")
    except BaseException as error:
        if child is not None and not (isinstance(error, InstallError) and str(error) == "active_entry"):
            terminate_owned(child)
        raise


def install(port, digest, payload, home=None):
    if sys.version_info < (3, 9):
        fail("python_unsupported")
    if type(port) is not int or not 1 <= port <= 65535 or not isinstance(digest, str) or not HEX.fullmatch(digest):
        fail("arguments_invalid")
    if len(payload) > PAYLOAD_LIMIT:
        fail("payload_too_large")
    if not payload:
        fail("payload_invalid")
    if hashlib.sha256(payload).hexdigest() != digest:
        fail("payload_hash_mismatch")
    try:
        compile(payload, "relay.py", "exec")
    except (SyntaxError, ValueError):
        fail("payload_invalid")
    home = Path.home() if home is None else Path(home)
    if not home.is_absolute() or any(ord(c) < 32 or ord(c) == 127 for c in str(home)):
        fail("home_unsafe")
    home_info = home.lstat()
    if (not stat.S_ISDIR(home_info.st_mode) or home_info.st_uid != os.getuid()
            or stat.S_IMODE(home_info.st_mode) & 0o022):
        fail("home_unsafe")
    base = home / ".catunnel" / "fixed-entry"
    target = base / str(port)
    helper, runtime, log = target / "relay.py", target / "r", target / "relay.log"
    # Unix-domain sockaddr paths include a terminating NUL; macOS is the tighter supported limit.
    if len(os.fsencode(runtime / "control.sock")) >= (104 if sys.platform == "darwin" else 108):
        fail("path_too_long")
    directory(base.parent, create=True)
    directory(base, create=True)
    install_lock = open_file(base / (str(port) + ".install.lock"), os.O_RDWR | os.O_CREAT)
    try:
        try:
            fcntl.flock(install_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail("install_busy")
        manifest = {"version": 1, "port": port, "sha256": digest, "helper": "relay.py", "runtime": "r"}
        if os.path.lexists(target):
            directory(target)
            names(target, ("relay.py", "manifest.json", "r", "relay.log"))
            if not all(os.path.lexists(target / name) for name in ("relay.py", "manifest.json", "r")):
                fail("installation_unknown")
            if read_json(target / "manifest.json") != manifest:
                fail("installation_mismatch")
            if hashlib.sha256(read_file(helper, PAYLOAD_LIMIT)).hexdigest() != digest:
                fail("installation_mismatch")
            if os.path.lexists(log):
                os.close(open_file(log))
            if runtime_running(runtime):
                pid = helper_status(runtime, port)
                return dict(version=1, ok=True, port=port, helper_path=str(helper), runtime_path=str(runtime),
                            sha256=digest, pid=pid, reused=True)
            port_available(port)
        else:
            port_available(port)
            # The per-port lock serializes installers. Partial installation is intentionally rejected
            # after a hard crash, so unknown contents can never be silently adopted or deleted.
            initialize(target, runtime, helper, payload, manifest)
        pid = start_helper(helper, runtime, port, log)
        return dict(version=1, ok=True, port=port, helper_path=str(helper), runtime_path=str(runtime),
                    sha256=digest, pid=pid, reused=False)
    finally:
        os.close(install_lock)


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        fail("arguments_invalid")


def interrupted(signum, frame):
    fail("interrupted")


def main(argv=None):
    os.umask(0o077)
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    try:
        parser = Arguments(add_help=False)
        parser.add_argument("--port", required=True, type=int)
        parser.add_argument("--sha256", required=True)
        args = parser.parse_args(argv)
        payload = sys.stdin.buffer.read(PAYLOAD_LIMIT + 1)
        result = install(args.port, args.sha256, payload)
    except InstallError as error:
        result = dict(version=1, ok=False, error=str(error))
    except Exception:
        result = dict(version=1, ok=False, error="install_io_failed")
    try:
        sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, OSError):
        return 1
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
