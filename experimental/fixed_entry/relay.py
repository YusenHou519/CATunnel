#!/usr/bin/env python3
"""Opt-in fixed-entry relay. No SSH processes, public requests, or persistent secrets."""
import argparse
import asyncio
import contextlib
from dataclasses import dataclass
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import sys
import time

LINE_LIMIT = 4096
IO_TIMEOUT = 3.0
MAX_DATA = 64
MAX_CONTROL = 16
BUFFER_SIZE = 65536
HEALTH_PREFIX = b"CATUNNEL-HEALTH-1 "
HEX_KEY = re.compile(r"[0-9a-f]{64}\Z")


class RelayError(Exception):
    pass


def validate_runtime(path, create=False):
    path = Path(path).absolute()
    if create:
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise RelayError("runtime_missing") from None
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise RelayError("runtime_unsafe")
    return path


def integer(value, minimum=0, maximum=None):
    return type(value) is int and value >= minimum and (maximum is None or value <= maximum)


def key(value):
    return isinstance(value, str) and HEX_KEY.fullmatch(value) is not None


def decode_line(line):
    if len(line) > LINE_LIMIT:
        raise RelayError("line_too_long")
    if not line.endswith(b"\n"):
        raise RelayError("request_invalid")
    try:
        result = json.loads(line.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise RelayError("request_invalid") from None
    if not isinstance(result, dict):
        raise RelayError("request_invalid")
    return result


async def read_line(reader):
    try:
        line = await asyncio.wait_for(reader.readline(), IO_TIMEOUT)
    except ValueError:
        raise RelayError("line_too_long") from None
    except asyncio.TimeoutError:
        raise RelayError("control_timeout") from None
    decode_line(line)
    return line


async def close_writer(writer):
    writer.close()
    with contextlib.suppress(Exception):
        await asyncio.wait_for(writer.wait_closed(), 1)


@dataclass(repr=False)
class Candidate:
    generation: int
    ticket: str
    expires: float


@dataclass(repr=False)
class Route(Candidate):
    backend_port: int
    health_key: str


class Relay:
    def __init__(self, runtime_dir, port=0, lease_seconds=20, idle_seconds=60):
        if not integer(port, 0, 65535) or not 0 < lease_seconds <= 3600 or not 0 < idle_seconds <= 3600:
            raise RelayError("configuration_invalid")
        self.runtime = Path(runtime_dir)
        self.port, self.lease_seconds, self.idle_seconds = port, lease_seconds, idle_seconds
        self.epoch, self.generation = secrets.token_hex(16), 0
        self.pending = self.active = None
        self.entry = self.control_server = self.maintenance = None
        self.lock_fd = None
        self.owned_paths = {}
        self.data_tasks, self.control_tasks, self.connections = set(), set(), {}
        self.closed = False

    async def start(self):
        if self.closed or self.lock_fd is not None:
            raise RelayError("already_started")
        self.runtime = validate_runtime(self.runtime, create=True)
        try:
            self.lock_fd = os.open(str(self.runtime / "relay.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            info = os.fstat(self.lock_fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
                raise RelayError("runtime_unsafe")
            try:
                fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RelayError("runtime_busy") from None
            # A crash may leave these paths behind. Require operator review instead of unlinking unknown files.
            for name in ("control.sock", "ready.json"):
                if os.path.lexists(self.runtime / name):
                    raise RelayError("runtime_not_clean")
            self.entry = await asyncio.start_server(lambda r, w: self._accept(r, w, False),
                                                   "127.0.0.1", self.port, limit=BUFFER_SIZE, backlog=MAX_DATA)
            self.port = self.entry.sockets[0].getsockname()[1]
            socket_path = self.runtime / "control.sock"
            self.control_server = await asyncio.start_unix_server(lambda r, w: self._accept(r, w, True),
                                                                  path=str(socket_path), limit=LINE_LIMIT)
            self._own(socket_path)
            os.chmod(socket_path, 0o600)
            ready = self.runtime / "ready.json"
            fd = os.open(str(ready), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            self._own(ready)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                json.dump({"port": self.port, "epoch": self.epoch, "pid": os.getpid()}, output)
                output.write("\n")
            self.maintenance = asyncio.create_task(self._expire_loop())
        except BaseException:
            await self.close()
            raise
        return self

    def _own(self, path):
        info = path.lstat()
        self.owned_paths[path] = (info.st_dev, info.st_ino)

    def _accept(self, reader, writer, control):
        tasks, limit = (self.control_tasks, MAX_CONTROL) if control else (self.data_tasks, MAX_DATA)
        if self.closed or len(tasks) >= limit:
            writer.close()
            return
        task = asyncio.create_task(self._control_connection(reader, writer) if control else self._data_connection(reader, writer))
        tasks.add(task)

        def finished(completed):
            tasks.discard(completed)
            writer.close()  # Also covers cancellation before the coroutine first runs.

        task.add_done_callback(finished)

    def _retire(self, route):
        if self.active is route:
            self.active = None
        for task, (owner, _) in list(self.connections.items()):
            if owner is route:
                task.cancel()

    def _expire(self):
        now = time.monotonic()
        if self.pending and self.pending.expires <= now:
            self.pending = None
        if self.active and self.active.expires <= now:
            self._retire(self.active)

    async def _expire_loop(self):
        while True:
            self._expire()
            await asyncio.sleep(min(0.25, self.lease_seconds / 4))

    def _identity(self, request, item, error):
        if request.get("epoch") != self.epoch:
            raise RelayError("epoch_mismatch")
        generation = request.get("generation")
        if (integer(generation, 1) and generation < self.generation
                and (not item or item.generation != generation)):
            raise RelayError("superseded")
        if not item or not integer(request.get("generation"), 1) or not key(request.get("ticket")):
            raise RelayError(error)
        if item.generation != request["generation"] or not hmac.compare_digest(item.ticket, request["ticket"]):
            raise RelayError(error)

    async def _health(self, port, health_key):
        async def check():
            reader, writer = await asyncio.open_connection("127.0.0.1", port, limit=256)
            try:
                challenge = secrets.token_hex(32).encode("ascii")
                writer.write(HEALTH_PREFIX + challenge + b"\n")
                await writer.drain()
                expected = hmac.new(bytes.fromhex(health_key), challenge, hashlib.sha256).hexdigest().encode("ascii")
                response = await reader.readline()
                return hmac.compare_digest(response, HEALTH_PREFIX + expected + b"\n")
            finally:
                writer.close()
        try:
            return await asyncio.wait_for(check(), IO_TIMEOUT)
        except (OSError, ValueError, asyncio.TimeoutError):
            return False

    async def control(self, request):
        try:
            if self.closed or not isinstance(request, dict):
                raise RelayError("request_invalid")
            self._expire()
            op = request.get("op")
            if op == "status":
                return dict(ok=True, epoch=self.epoch, generation=self.generation, port=self.port,
                            active_generation=self.active.generation if self.active else None,
                            backend_port=self.active.backend_port if self.active else None, lease_seconds=self.lease_seconds)
            if op == "begin":
                if request.get("epoch") != self.epoch:
                    raise RelayError("epoch_mismatch")
                expected = request.get("expected_generation")
                if not integer(expected) or expected != self.generation:
                    raise RelayError("stale_generation")
                self.generation += 1
                self.pending = Candidate(self.generation, secrets.token_hex(32), time.monotonic() + 30)
                return dict(ok=True, epoch=self.epoch, generation=self.generation, ticket=self.pending.ticket)
            if op == "activate":
                candidate = self.pending
                self._identity(request, candidate, "stale_candidate")
                port, health_key = request.get("backend_port"), request.get("health_key")
                if not integer(port, 1, 65535) or port == self.port or not key(health_key):
                    raise RelayError("backend_invalid")
                healthy = await self._health(port, health_key)
                self._expire()
                if self.closed or self.pending is not candidate:
                    if not self.closed:
                        self._identity(request, self.pending, "stale_candidate")
                    raise RelayError("stale_candidate")
                if not healthy:
                    raise RelayError("health_failed")
                previous = self.active
                self.active = Route(candidate.generation, candidate.ticket, time.monotonic() + self.lease_seconds, port, health_key)
                self.pending = None
                if previous:
                    self._retire(previous)
                return dict(ok=True, epoch=self.epoch, generation=candidate.generation, backend_port=port, lease_seconds=self.lease_seconds)
            if op in ("renew", "release"):
                route = self.active
                self._identity(request, route, "stale_lease")
                if op == "release":
                    self._retire(route)
                    return dict(ok=True)
                healthy = await self._health(route.backend_port, route.health_key)
                self._expire()
                if self.closed or self.active is not route:
                    if not self.closed:
                        self._identity(request, self.active, "stale_lease")
                    raise RelayError("stale_lease")
                if not healthy:
                    self._retire(route)
                    raise RelayError("health_failed")
                route.expires = time.monotonic() + self.lease_seconds
                return dict(ok=True, lease_seconds=self.lease_seconds)
            raise RelayError("unknown_operation")
        except RelayError as error:
            return dict(ok=False, error=str(error))

    async def _control_connection(self, reader, writer):
        try:
            try:
                response = await self.control(decode_line(await read_line(reader)))
            except RelayError as error:
                response = dict(ok=False, error=str(error))
            except (OSError, asyncio.TimeoutError):
                response = dict(ok=False, error="control_io_failed")
            writer.write(json.dumps(response, separators=(",", ":")).encode("utf-8") + b"\n")
            await asyncio.wait_for(writer.drain(), IO_TIMEOUT)
        except (OSError, asyncio.TimeoutError):
            pass
        finally:
            await close_writer(writer)

    async def _data_connection(self, reader, writer):
        self._expire()
        route, task = self.active, asyncio.current_task()
        writers = [writer]
        self.connections[task] = (route, writers)
        pumps = []
        try:
            if not route:
                return
            backend, upstream = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", route.backend_port,
                                                                                limit=BUFFER_SIZE), IO_TIMEOUT)
            writers.append(upstream)
            self._expire()
            if self.active is not route:
                return
            activity = [time.monotonic()]

            async def copy(source, destination):
                while True:
                    chunk = await source.read(BUFFER_SIZE)
                    if not chunk:
                        if destination.can_write_eof():
                            destination.write_eof()
                            await destination.drain()
                        return
                    destination.write(chunk)
                    await destination.drain()
                    activity[0] = time.monotonic()

            pumps = [asyncio.create_task(copy(reader, upstream)), asyncio.create_task(copy(backend, writer))]
            while not all(pump.done() for pump in pumps):
                await asyncio.wait(pumps, timeout=min(0.25, self.idle_seconds), return_when=asyncio.FIRST_EXCEPTION)
                for pump in pumps:
                    if pump.done() and pump.exception():
                        raise pump.exception()
                if time.monotonic() - activity[0] >= self.idle_seconds:
                    return
        except (OSError, asyncio.TimeoutError):
            pass
        finally:
            for pump in pumps:
                pump.cancel()
            # A second cancellation must not interrupt cleanup before sockets are closed.
            for output in writers:
                output.close()
            await asyncio.gather(*pumps, return_exceptions=True)
            for output in writers:
                await close_writer(output)
            self.connections.pop(task, None)

    async def close(self):
        self.closed = True
        for server in (self.entry, self.control_server):
            if server:
                server.close()
                await server.wait_closed()
        tasks = list(self.data_tasks | self.control_tasks)
        if self.maintenance:
            tasks.append(self.maintenance)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.pending = self.active = None
        for path, identity in self.owned_paths.items():
            with contextlib.suppress(FileNotFoundError):
                info = path.lstat()
                if (info.st_dev, info.st_ino) == identity:
                    path.unlink()
        self.owned_paths.clear()
        if self.lock_fd is not None:
            os.close(self.lock_fd)
            self.lock_fd = None


async def cli(args):
    if args.action == "serve":
        relay = Relay(args.runtime_dir, args.port, args.lease_seconds)
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for signum in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(signum, stop.set)
        try:
            await relay.start()
            await stop.wait()
        finally:
            await relay.close()
        return
    runtime = validate_runtime(args.runtime_dir)
    reader = asyncio.StreamReader(limit=LINE_LIMIT)
    transport, _ = await asyncio.get_running_loop().connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    try:
        line = await read_line(reader)
    finally:
        transport.close()
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(str(runtime / "control.sock"), limit=LINE_LIMIT), IO_TIMEOUT)
    except (OSError, asyncio.TimeoutError):
        raise RelayError("helper_unavailable") from None
    try:
        writer.write(line)
        await asyncio.wait_for(writer.drain(), IO_TIMEOUT)
        response = await read_line(reader)
        if type(decode_line(response).get("ok")) is not bool:
            raise RelayError("response_invalid")
        sys.stdout.buffer.write(response)
        sys.stdout.buffer.flush()
    finally:
        await close_writer(writer)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--runtime-dir", required=True)
    serve.add_argument("--port", type=int, required=True)
    serve.add_argument("--lease-seconds", type=float, default=20)
    control = commands.add_parser("control")
    control.add_argument("--runtime-dir", required=True)
    args = parser.parse_args()
    try:
        asyncio.run(cli(args))
        return 0
    except (RelayError, OSError, ValueError) as error:
        code = str(error) if isinstance(error, RelayError) else "helper_io_failed"
        if args.action == "control":
            print(json.dumps(dict(ok=False, error=code)))
        else:
            print(code, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
