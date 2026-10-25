"""Loopback-only gateway for the opt-in fixed-entry experiment."""

import asyncio
import hashlib
import hmac
import re


HEALTH_PREFIX = b"CATUNNEL-HEALTH-1 "
HEALTH_REQUEST = re.compile(rb"CATUNNEL-HEALTH-1 ([0-9a-f]{64})\n")


async def close_writer(writer):
    writer.close()
    try:
        await asyncio.wait_for(writer.wait_closed(), 1)
    except (OSError, asyncio.TimeoutError):
        pass


async def transfer(left_reader, left_writer, right_reader, right_writer, idle_timeout):
    """Bounded buffers, a shared idle deadline, and independent TCP half-closes."""
    loop = asyncio.get_running_loop()
    activity = loop.time()

    async def pump(reader, writer):
        nonlocal activity
        while True:
            data = await reader.read(16384)
            if not data:
                if writer.can_write_eof():
                    writer.write_eof()
                    await writer.drain()
                return
            activity = loop.time()
            writer.write(data)
            await writer.drain()

    async def idle():
        while True:
            remaining = idle_timeout - (loop.time() - activity)
            if remaining <= 0:
                raise asyncio.TimeoutError()
            await asyncio.sleep(min(remaining, 0.5))

    pumps = [asyncio.create_task(pump(left_reader, right_writer)),
             asyncio.create_task(pump(right_reader, left_writer))]
    joined = asyncio.gather(*pumps)
    watchdog = asyncio.create_task(idle())
    try:
        done, _ = await asyncio.wait([joined, watchdog], return_when=asyncio.FIRST_COMPLETED)
        for finished in done:
            await finished
    finally:
        joined.cancel()
        watchdog.cancel()
        for task in pumps:
            task.cancel()
        await asyncio.gather(joined, watchdog, *pumps, return_exceptions=True)


class Gateway:
    def __init__(self, local_port, health_key, *, idle_timeout=60, max_connections=64):
        if isinstance(local_port, bool) or not isinstance(local_port, int) or not 1 <= local_port <= 65535:
            raise ValueError("Invalid local proxy port")
        if not isinstance(health_key, bytes) or len(health_key) != 32:
            raise ValueError("Health key must contain 32 bytes")
        if idle_timeout <= 0 or max_connections < 1:
            raise ValueError("Invalid gateway limits")
        self._local_port, self._key = local_port, health_key
        self._idle_timeout, self._max_connections = idle_timeout, max_connections
        self._server = None
        self._tasks = set()
        self._writers = set()
        self._stopping = False

    @property
    def port(self):
        return self._server.sockets[0].getsockname()[1] if self._server and self._server.sockets else None

    async def start(self):
        if self._server is not None or self._stopping:
            raise RuntimeError("Gateway cannot be started twice")
        self._server = await asyncio.start_server(self._accept, "127.0.0.1", 0, limit=32768)
        if self.port == self._local_port:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
            raise ValueError("Gateway port conflicts with the configured local proxy port")
        return self.port

    def _accept(self, reader, writer):
        if self._stopping or len(self._tasks) >= self._max_connections:
            writer.close()
            return
        self._writers.add(writer)
        task = asyncio.create_task(self._handle(reader, writer))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _prefix(self, reader):
        initial = bytearray()
        # CONNECT diverges at its second byte; SOCKS and other HTTP methods at the first.
        for expected in b"CATUNNEL-":
            byte = await reader.read(1)
            if not byte:
                return False, bytes(initial)
            initial.extend(byte)
            if byte[0] != expected:
                return False, bytes(initial)
        while len(initial) <= 128:
            byte = await reader.read(1)
            if not byte:
                break
            initial.extend(byte)
            if byte == b"\n":
                break
        return True, bytes(initial)

    async def _handle(self, reader, writer):
        upstream = None
        try:
            is_health, initial = await asyncio.wait_for(self._prefix(reader), 3)
            if is_health:
                match = HEALTH_REQUEST.fullmatch(initial)
                if match is None:
                    return
                _, upstream = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", self._local_port), 3)
                self._writers.add(upstream)
                await close_writer(upstream)
                digest = hmac.new(self._key, match.group(1), hashlib.sha256).hexdigest().encode("ascii")
                writer.write(HEALTH_PREFIX + digest + b"\n")
                await asyncio.wait_for(writer.drain(), 3)
                return
            if not initial:
                return
            upstream_reader, upstream = await asyncio.wait_for(
                asyncio.open_connection("127.0.0.1", self._local_port, limit=32768), 3)
            self._writers.add(upstream)
            upstream.write(initial)
            await asyncio.wait_for(upstream.drain(), 3)
            await transfer(reader, writer, upstream_reader, upstream, self._idle_timeout)
        except (OSError, asyncio.TimeoutError, ValueError):
            pass
        finally:
            for stream in (writer, upstream):
                if stream is not None:
                    await close_writer(stream)
                    self._writers.discard(stream)

    async def stop(self):
        self._stopping = True
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
        for writer in tuple(self._writers):
            writer.close()
        tasks = tuple(self._tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self._tasks.clear()
        self._writers.clear()
