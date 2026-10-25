"""Explicit CLI client for the isolated fixed-entry prototype, not the GUI app."""

import argparse
import asyncio
import json
import math
import os
import pathlib
import re
import secrets
import shlex
import signal
import sys
import tempfile

try:
    from .gateway import Gateway
except ImportError:
    from gateway import Gateway


HEX_KEY = re.compile(r"[0-9a-f]{64}\Z")
PERMANENT_REMOTE_ERRORS = {"runtime_missing", "runtime_unsafe", "helper_unavailable", "superseded", "stale_generation"}
REMOTE_ERRORS = PERMANENT_REMOTE_ERRORS | {
    "request_invalid", "line_too_long", "control_timeout", "epoch_mismatch", "stale_generation",
    "stale_candidate", "stale_lease", "health_failed", "backend_invalid", "runtime_busy", "runtime_not_clean"}


class ClientError(Exception):
    def __init__(self, code, message, *, fatal=False):
        super().__init__(message)
        self.code, self.fatal = code, fatal


def valid_port(value):
    return isinstance(value, int) and not isinstance(value, bool) and 1 <= value <= 65535


class FixedEntryClient:
    def __init__(self, *, host, user, ssh_port, identity_file, known_hosts_file, remote_helper,
                 remote_runtime, local_port, on_event=None):
        if not isinstance(host, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]*", host):
            raise ValueError("Invalid SSH host")
        if not isinstance(user, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*\$?", user):
            raise ValueError("Invalid SSH user")
        if not valid_port(ssh_port) or not valid_port(local_port):
            raise ValueError("Invalid SSH or local proxy port")
        paths = [identity_file, known_hosts_file, remote_helper, remote_runtime]
        if any(not isinstance(path, (str, os.PathLike)) or not str(path)
               or any(ord(char) < 32 or ord(char) == 127 for char in str(path)) for path in paths):
            raise ValueError("Invalid explicit SSH/helper path")
        self._identity = os.path.abspath(os.path.expanduser(str(identity_file)))
        self._known_hosts = os.path.abspath(os.path.expanduser(str(known_hosts_file)))
        if not pathlib.Path(self._identity).is_file() or not pathlib.Path(self._known_hosts).is_file():
            raise ValueError("Explicit identity and known-hosts files must exist")
        if not str(remote_helper).startswith("/") or not str(remote_runtime).startswith("/"):
            raise ValueError("Remote helper and runtime paths must be absolute")
        self._host, self._user, self._ssh_port, self._local_port = host, user, ssh_port, local_port
        self._remote_helper, self._remote_runtime = str(remote_helper), str(remote_runtime)
        self._on_event = on_event
        self._master = self._master_reader = self._master_wait = None
        self._master_stderr = bytearray()
        self._children = set()
        self._gateway = self._temporary = None
        self._lease = None
        self._generation_guard = None
        self._connected, self._backend_port = False, None
        self._run_task = None
        self._started = self._stop_requested = self._stopped_emitted = False
        self._stop_event = asyncio.Event()

    @property
    def master_pid(self):
        return self._master.pid if self._master and self._master.returncode is None else None

    @property
    def connected(self):
        return self._connected

    @property
    def backend_port(self):
        return self._backend_port

    @property
    def gateway_port(self):
        return self._gateway.port if self._gateway else None

    @property
    def control_directory(self):
        return self._temporary.name if self._temporary else None

    def _emit(self, event, **fields):
        if self._on_event is not None:
            try:
                self._on_event({"event": event, **fields})
            except Exception:
                pass

    def _base(self):
        return ["/usr/bin/ssh", "-F", "/dev/null", "-S", self.control_directory + "/c",
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
                "-o", "CheckHostIP=no", "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "UserKnownHostsFile=" + self._known_hosts, "-o", "IdentityAgent=none",
                "-o", "IdentitiesOnly=yes", "-i", self._identity, "-p", str(self._ssh_port),
                "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "LogLevel=ERROR"]

    def _destination(self):
        return self._user + "@" + self._host

    def _master_arguments(self):
        return self._base() + ["-M", "-o", "ControlPersist=no", "-o", "ExitOnForwardFailure=yes",
                              "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                              "-N", "-T", self._destination()]

    def _mux_arguments(self, operation, *options):
        return self._base() + ["-o", "ProxyCommand=/usr/bin/false", "-O", operation,
                              *options, self._destination()]

    def _remote_arguments(self):
        command = shlex.join(["python3", self._remote_helper, "control", "--runtime-dir", self._remote_runtime])
        return self._base() + ["-o", "ControlMaster=no", "-o", "ClearAllForwardings=yes",
                              "-o", "ProxyCommand=/usr/bin/false", "-T", self._destination(), command]

    async def _spawn(self, arguments, **pipes):
        creation = asyncio.create_task(asyncio.create_subprocess_exec(*arguments, **pipes))
        try:
            process = await asyncio.shield(creation)
        except asyncio.CancelledError:
            process = await creation
            await self._terminate(process)
            raise
        self._children.add(process)
        return process

    @staticmethod
    async def _terminate(process):
        if process.returncode is not None:
            return
        try:
            process.terminate()
        except ProcessLookupError:
            pass
        try:
            await asyncio.wait_for(process.wait(), 2)
        except asyncio.TimeoutError:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            await process.wait()

    @staticmethod
    def _ssh_failure(stderr):
        text = stderr.decode("utf-8", errors="replace").lower()
        if any(pattern in text for pattern in (
                "permission denied", "authentication failed", "host key verification failed",
                "remote host identification has changed", "no such identity", "invalid format",
                "sign_and_send_pubkey", "bad permissions")):
            return ClientError("ssh_identity", "SSH authentication or host-key verification failed", fatal=True)
        return ClientError("ssh_transport", "Owned SSH transport is unavailable")

    async def _command(self, arguments, payload=None, timeout=8):
        process = await self._spawn(arguments, stdin=asyncio.subprocess.PIPE,
                                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)

        async def bounded(reader):
            data = bytearray()
            while True:
                chunk = await reader.read(min(4096, 8193 - len(data)))
                if not chunk:
                    return bytes(data)
                data.extend(chunk)
                if len(data) > 8192:
                    raise ClientError("response_too_large", "SSH command output exceeded its limit")

        async def exchange():
            if payload:
                try:
                    process.stdin.write(payload)
                    await process.stdin.drain()
                except (BrokenPipeError, ConnectionResetError):
                    pass
            process.stdin.close()
            out, err, code = await asyncio.gather(bounded(process.stdout), bounded(process.stderr), process.wait())
            return code, out, err

        try:
            return await asyncio.wait_for(exchange(), timeout)
        except asyncio.TimeoutError:
            raise ClientError("ssh_timeout", "Owned SSH operation timed out") from None
        finally:
            await self._terminate(process)
            self._children.discard(process)

    async def _read_master_stderr(self):
        while True:
            chunk = await self._master.stderr.read(4096)
            if not chunk:
                return
            remaining = 8192 - len(self._master_stderr)
            self._master_stderr.extend(chunk[:max(0, remaining)])

    async def _control(self, request, timeout=8):
        payload = json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n"
        if len(payload) > 4096:
            raise ClientError("request_invalid", "Control request exceeded its limit", fatal=True)
        code, output, stderr = await self._command(self._remote_arguments(), payload, timeout)
        result = None
        if len(output) <= 4096 and output.endswith(b"\n") and output.count(b"\n") == 1:
            try:
                decoded = json.loads(output)
                if isinstance(decoded, dict) and isinstance(decoded.get("ok"), bool):
                    result = decoded
            except (ValueError, UnicodeError):
                pass
        # The helper uses a nonzero exit code for a valid structured rejection.
        if result is not None and not result["ok"] and code != 255:
            code = result.get("error")
            safe_code = code if isinstance(code, str) and code in REMOTE_ERRORS else "remote_failure"
            raise ClientError(safe_code, "Remote helper rejected operation: " + safe_code,
                              fatal=safe_code in PERMANENT_REMOTE_ERRORS)
        if code != 0:
            diagnostic = stderr.decode("utf-8", errors="replace").lower()
            if "can't open file" in diagnostic or "python3: not found" in diagnostic or "python3: command not found" in diagnostic:
                raise ClientError("helper_missing", "Remote Python/helper executable is missing", fatal=True)
            raise self._ssh_failure(stderr)
        if result is None:
            raise ClientError("response_invalid", "Remote helper returned an invalid control response")
        return result

    @staticmethod
    def _lease_seconds(result):
        value = result.get("lease_seconds")
        if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value <= 0:
            raise ClientError("response_invalid", "Remote helper returned an invalid lease duration")
        return value

    async def _connect(self):
        self._temporary = tempfile.TemporaryDirectory(prefix="ctfe.")
        if len(os.fsencode(self.control_directory + "/c")) >= 104:
            raise ClientError("socket_path", "Private SSH control path is too long", fatal=True)
        key = secrets.token_bytes(32)
        self._gateway = Gateway(self._local_port, key)
        await self._gateway.start()
        self._master_stderr.clear()
        self._master = await self._spawn(self._master_arguments(), stdin=asyncio.subprocess.DEVNULL,
                                         stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        self._master_reader = asyncio.create_task(self._read_master_stderr())
        self._master_wait = asyncio.create_task(self._master.wait())
        deadline = asyncio.get_running_loop().time() + 12
        while True:
            if self._master.returncode is not None:
                await self._master_reader
                raise self._ssh_failure(bytes(self._master_stderr))
            if os.path.exists(self.control_directory + "/c"):
                code, _, _ = await self._command(self._mux_arguments("check"), timeout=3)
                if code == 0:
                    break
            if asyncio.get_running_loop().time() >= deadline:
                raise ClientError("ssh_timeout", "SSH master did not become ready")
            await asyncio.sleep(0.1)
        forward = "127.0.0.1:0:127.0.0.1:" + str(self.gateway_port)
        code, output, stderr = await self._command(self._mux_arguments("forward", "-R", forward))
        if code != 0:
            raise self._ssh_failure(stderr)
        if not re.fullmatch(rb"[0-9]+\s*", output) or not valid_port(int(output)):
            raise ClientError("backend_invalid", "SSH did not report a valid allocated reverse port")
        port = int(output)
        return await self._establish_lease(port, key)

    async def _establish_lease(self, port, key):
        status = await self._control({"op": "status"})
        epoch, generation = status.get("epoch"), status.get("generation")
        if not isinstance(epoch, str) or not epoch or len(epoch) > 128 or not valid_port(status.get("port")) \
                or not isinstance(generation, int) or isinstance(generation, bool) or generation < 0:
            raise ClientError("response_invalid", "Remote helper status is invalid")
        if self._generation_guard is not None:
            previous_epoch, previous_generation = self._generation_guard
            if epoch == previous_epoch and generation > previous_generation:
                raise ClientError("superseded", "A newer client owns the entry generation", fatal=True)
        # Keep this baseline across transport cleanup. If begin's response is lost,
        # a later generation is ambiguous and must not be taken over automatically.
        self._generation_guard = (epoch, generation)
        candidate = await self._control({"op": "begin", "epoch": epoch, "expected_generation": generation})
        ticket = candidate.get("ticket")
        if candidate.get("epoch") != epoch or candidate.get("generation") != generation + 1 \
                or isinstance(candidate.get("generation"), bool) \
                or not isinstance(ticket, str) or not HEX_KEY.fullmatch(ticket):
            raise ClientError("response_invalid", "Remote helper candidate is invalid")
        self._generation_guard = (epoch, generation + 1)
        lease = {"epoch": epoch, "generation": generation + 1, "ticket": ticket}
        self._lease = lease
        activation = await self._control({"op": "activate", **lease, "backend_port": port, "health_key": key.hex()})
        if activation.get("epoch") != epoch or activation.get("generation") != generation + 1 \
                or activation.get("backend_port") != port:
            raise ClientError("response_invalid", "Remote helper activation is invalid")
        seconds = self._lease_seconds(activation)
        self._lease, self._backend_port, self._connected = lease, port, True
        self._emit("connected", entry_port=status["port"], backend_port=port, generation=lease["generation"])
        return seconds

    async def _maintain(self, seconds):
        stop = asyncio.create_task(self._stop_event.wait())
        try:
            while not self._stop_requested:
                done, _ = await asyncio.wait([stop, self._master_wait], timeout=seconds / 3,
                                             return_when=asyncio.FIRST_COMPLETED)
                if stop in done:
                    return
                if self._master_wait in done:
                    await self._master_reader
                    raise self._ssh_failure(bytes(self._master_stderr))
                seconds = self._lease_seconds(await self._control({"op": "renew", **self._lease}))
        finally:
            stop.cancel()
            await asyncio.gather(stop, return_exceptions=True)

    async def _cleanup(self):
        self._connected = False
        if self._gateway is not None:
            await self._gateway.stop()
            self._gateway = None
        if self._lease is not None and self._master is not None and self._master.returncode is None:
            try:
                await self._control({"op": "release", **self._lease}, timeout=4)
            except (ClientError, OSError):
                pass
        self._lease = None
        self._backend_port = None
        for child in tuple(self._children):
            await self._terminate(child)
        self._children.clear()
        for task in (self._master_reader, self._master_wait):
            if task is not None:
                await asyncio.gather(task, return_exceptions=True)
        self._master = self._master_reader = self._master_wait = None
        if self._temporary is not None:
            self._temporary.cleanup()
            self._temporary = None

    async def run(self):
        if self._started:
            raise RuntimeError("A FixedEntryClient instance can run only once")
        self._started = True
        self._run_task = asyncio.current_task()
        backoff = 1
        try:
            while not self._stop_requested:
                try:
                    seconds = await self._connect()
                    backoff = 1
                    await self._maintain(seconds)
                except (ClientError, OSError) as error:
                    safe = error if isinstance(error, ClientError) else ClientError("local_io", "Local SSH/gateway operation failed")
                    if self._connected:
                        self._emit("disconnected", reason=safe.code)
                    await self._cleanup()
                    if safe.fatal:
                        self._emit("disconnected", reason=safe.code, message=str(safe))
                        raise safe
                    if not self._stop_requested:
                        self._emit("retrying", delay_seconds=backoff, reason=safe.code)
                        try:
                            await asyncio.wait_for(self._stop_event.wait(), backoff)
                        except asyncio.TimeoutError:
                            pass
                        backoff = min(30, backoff * 2)
        except asyncio.CancelledError:
            if not self._stop_requested:
                raise
        finally:
            self._stop_requested = True
            self._stop_event.set()
            await self._cleanup()
            self._emit_stopped()

    def _emit_stopped(self):
        if not self._stopped_emitted:
            self._stopped_emitted = True
            self._emit("stopped")

    async def stop(self):
        first = not self._stop_requested
        self._stop_requested = True
        self._stop_event.set()
        task = self._run_task
        if task is not None and task is not asyncio.current_task():
            if first and not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        elif task is None:
            await self._cleanup()
            self._emit_stopped()


async def connect(arguments):
    client = FixedEntryClient(**{name: getattr(arguments, name) for name in (
        "host", "user", "ssh_port", "identity_file", "known_hosts_file", "remote_helper", "remote_runtime", "local_port")},
        on_event=lambda event: print(json.dumps(event, sort_keys=True), flush=True))
    loop = asyncio.get_running_loop()
    for number in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(number, lambda: asyncio.create_task(client.stop()))
    try:
        await client.run()
    finally:
        await client.stop()
        for number in (signal.SIGINT, signal.SIGTERM):
            loop.remove_signal_handler(number)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("connect")
    for name in ("host", "user", "identity-file", "known-hosts-file", "remote-helper", "remote-runtime"):
        command.add_argument("--" + name, required=True)
    for name in ("ssh-port", "local-port"):
        command.add_argument("--" + name, required=True, type=int)
    arguments = parser.parse_args()
    try:
        asyncio.run(connect(arguments))
    except (ClientError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
