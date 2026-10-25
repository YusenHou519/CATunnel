import asyncio
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import stat
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import relay


class Backend:
    def __init__(self):
        self.key = secrets.token_hex(32)
        self.valid = True
        self.gate = asyncio.Event()
        self.gate.set()
        self.health_started = asyncio.Event()
        self.tasks = set()
        self.reply_on_eof = False

    async def start(self):
        self.server = await asyncio.start_server(self.handle, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def handle(self, reader, writer):
        task = asyncio.current_task()
        self.tasks.add(task)
        try:
            first = await reader.readline()
            if first.startswith(relay.HEALTH_PREFIX):
                self.health_started.set()
                await self.gate.wait()
                challenge = first[len(relay.HEALTH_PREFIX):-1]
                digest = hmac.new(bytes.fromhex(self.key), challenge, hashlib.sha256).hexdigest().encode("ascii")
                writer.write(relay.HEALTH_PREFIX + (digest if self.valid else b"0" * 64) + b"\n")
                await writer.drain()
            elif self.reply_on_eof:
                writer.write(b"reply:" + first + await reader.read())
                await writer.drain()
            else:
                writer.write(first)
                await writer.drain()
                while True:
                    data = await reader.read(65536)
                    if not data:
                        break
                    writer.write(data)
                    await writer.drain()
        except (OSError, asyncio.CancelledError):
            pass
        finally:
            await relay.close_writer(writer)
            self.tasks.discard(task)

    async def close(self):
        self.server.close()
        await self.server.wait_closed()
        for task in list(self.tasks):
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fentry-", dir="/tmp")
        self.root = Path(self.temporary.name)
        self.relays, self.backends, self.writers = [], [], []
        self.service = await self.make_relay("runtime")

    async def asyncTearDown(self):
        for writer in self.writers:
            await relay.close_writer(writer)
        for service in self.relays:
            await service.close()
        for backend in self.backends:
            await backend.close()
        self.temporary.cleanup()

    async def make_relay(self, name, **options):
        service = relay.Relay(self.root / name, **options)
        self.relays.append(service)
        await service.start()
        return service

    async def backend(self):
        backend = await Backend().start()
        self.backends.append(backend)
        return backend

    async def begin(self, service=None):
        service = service or self.service
        response = await service.control(dict(op="begin", epoch=service.epoch, expected_generation=service.generation))
        self.assertTrue(response["ok"], response.get("error"))
        return {name: response[name] for name in ("epoch", "generation", "ticket")}

    async def activate(self, backend, identity=None, service=None):
        service = service or self.service
        identity = identity or await self.begin(service)
        response = await service.control(dict(identity, op="activate", backend_port=backend.port, health_key=backend.key))
        self.assertTrue(response["ok"], response.get("error"))
        return identity

    async def connect(self, service=None):
        reader, writer = await asyncio.open_connection("127.0.0.1", (service or self.service).port)
        self.writers.append(writer)
        return reader, writer

    async def echo(self, service=None):
        reader, writer = await self.connect(service)
        payload = b"fixture\n" + bytes(range(256)) * 1000
        writer.write(payload)
        await writer.drain()
        actual = await asyncio.wait_for(reader.readexactly(len(payload)), 3)
        self.assertTrue(actual == payload, "Relay changed stream bytes")
        await relay.close_writer(writer)

    async def request(self, line):
        reader, writer = await asyncio.open_unix_connection(str(self.service.runtime / "control.sock"))
        try:
            writer.write(line)
            await writer.drain()
            return json.loads(await asyncio.wait_for(reader.readline(), 4))
        finally:
            await relay.close_writer(writer)

    async def test_private_runtime_status_and_no_backend(self):
        result = await self.service.control(dict(op="status"))
        self.assertEqual(set(result), {"ok", "epoch", "generation", "port", "active_generation", "backend_port", "lease_seconds"})
        self.assertTrue(result["ok"])
        self.assertIsNone(result["backend_port"])
        self.assertEqual(self.service.entry.sockets[0].getsockname()[0], "127.0.0.1")
        for name in ("relay.lock", "control.sock", "ready.json"):
            self.assertEqual(stat.S_IMODE((self.service.runtime / name).stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.service.runtime.stat().st_mode), 0o700)
        ready = json.loads((self.service.runtime / "ready.json").read_text())
        self.assertEqual(set(ready), {"port", "epoch", "pid"})
        reader, _ = await self.connect()
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")

    async def test_switch_closes_old_stream_and_stale_operations_cannot_change_route(self):
        first, second = await self.backend(), await self.backend()
        old = await self.activate(first)
        reader, writer = await self.connect()
        writer.write(b"old\n")
        await writer.drain()
        self.assertEqual(await reader.readline(), b"old\n")
        current = await self.activate(second)
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")
        for operation in ("renew", "release"):
            result = await self.service.control(dict(old, op=operation))
            self.assertEqual(result.get("error"), "superseded")
        self.assertEqual((await self.service.control(dict(op="status")))["active_generation"], current["generation"])
        await self.echo()

    async def test_failed_health_and_invalid_backend_preserve_active_route(self):
        good, wrong = await self.backend(), await self.backend()
        await self.activate(good)
        wrong.valid = False
        pending = await self.begin()
        result = await self.service.control(dict(pending, op="activate", backend_port=wrong.port, health_key=wrong.key))
        self.assertEqual(result.get("error"), "health_failed")
        for port in (self.service.port, 0, 65536, True):
            result = await self.service.control(dict(pending, op="activate", backend_port=port, health_key=wrong.key))
            self.assertEqual(result.get("error"), "backend_invalid")
        self.assertEqual((await self.service.control(dict(op="status")))["backend_port"], good.port)
        await self.echo()

    async def test_begin_cas_epoch_and_pending_expiry(self):
        pending = await self.begin()
        result = await self.service.control(dict(op="begin", epoch=self.service.epoch, expected_generation=0))
        self.assertEqual(result.get("error"), "stale_generation")
        result = await self.service.control(dict(op="begin", epoch="old-instance", expected_generation=1))
        self.assertEqual(result.get("error"), "epoch_mismatch")
        self.service.pending.expires = time.monotonic() - 1
        backend = await self.backend()
        result = await self.service.control(dict(pending, op="activate", backend_port=backend.port, health_key=backend.key))
        self.assertEqual(result.get("error"), "stale_candidate")
        next_identity = await self.begin()
        self.assertEqual(next_identity["generation"], 2)

    async def test_slow_activation_cannot_overwrite_new_candidate(self):
        slow, fresh = await self.backend(), await self.backend()
        slow.gate.clear()
        old = await self.begin()
        checking = asyncio.create_task(self.service.control(dict(old, op="activate", backend_port=slow.port, health_key=slow.key)))
        await asyncio.wait_for(slow.health_started.wait(), 1)
        current = await self.activate(fresh)
        slow.gate.set()
        self.assertEqual((await checking).get("error"), "superseded")
        self.assertEqual((await self.service.control(dict(op="status")))["active_generation"], current["generation"])
        await self.echo()

    async def test_slow_failed_renew_cannot_clear_new_active_route(self):
        slow, fresh = await self.backend(), await self.backend()
        old = await self.activate(slow)
        slow.health_started.clear()
        slow.gate.clear()
        slow.valid = False
        checking = asyncio.create_task(self.service.control(dict(old, op="renew")))
        await asyncio.wait_for(slow.health_started.wait(), 1)
        current = await self.activate(fresh)
        slow.gate.set()
        self.assertEqual((await checking).get("error"), "superseded")
        self.assertEqual((await self.service.control(dict(op="status")))["active_generation"], current["generation"])
        await self.echo()

    async def test_lease_expiry_keeps_listener_and_closes_owned_streams(self):
        service = await self.make_relay("expiry", lease_seconds=0.15)
        backend = await self.backend()
        await self.activate(backend, service=service)
        reader, writer = await self.connect(service)
        writer.write(b"active\n")
        await writer.drain()
        self.assertEqual(await reader.readline(), b"active\n")
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")
        self.assertIsNone((await service.control(dict(op="status")))["backend_port"])
        reader, _ = await self.connect(service)
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")
        self.assertTrue(service.entry.is_serving())
        result = await service.control(dict(epoch=service.epoch, generation=service.generation,
                                            ticket=secrets.token_hex(32), op="renew"))
        self.assertEqual(result.get("error"), "stale_lease")

    async def test_renew_checks_health_extends_lease_and_release_is_explicit(self):
        backend = await self.backend()
        identity = await self.activate(backend)
        self.service.active.expires = time.monotonic() + 1
        result = await self.service.control(dict(identity, op="renew"))
        self.assertTrue(result["ok"], result.get("error"))
        self.assertGreater(self.service.active.expires, time.monotonic() + 10)
        backend.valid = False
        result = await self.service.control(dict(identity, op="renew"))
        self.assertEqual(result.get("error"), "health_failed")
        self.assertIsNone(self.service.active)
        backend.valid = True
        current = await self.activate(backend)
        result = await self.service.control(dict(current, op="release"))
        self.assertTrue(result["ok"])
        self.assertIsNone(self.service.active)

    async def test_half_close_and_shared_idle_deadline(self):
        backend = await self.backend()
        backend.reply_on_eof = True
        await self.activate(backend)
        reader, writer = await self.connect()
        writer.write(b"request\nbody")
        writer.write_eof()
        self.assertEqual(await asyncio.wait_for(reader.read(), 2), b"reply:request\nbody")
        idle = await self.make_relay("idle", idle_seconds=0.15)
        backend.reply_on_eof = False
        await self.activate(backend, service=idle)
        reader, _ = await self.connect(idle)
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")

    async def test_bounded_control_lines_and_health_timeout(self):
        result = await self.request(b"x" * (relay.LINE_LIMIT + 1) + b"\n")
        self.assertEqual(result.get("error"), "line_too_long")
        self.assertEqual((await self.request(b"[]\n")).get("error"), "request_invalid")
        self.assertTrue((await self.request(b'{"op":"status"}\n'))["ok"])
        backend = await self.backend()
        backend.gate.clear()
        pending = await self.begin()
        with mock.patch.object(relay, "IO_TIMEOUT", 0.1):
            result = await self.service.control(dict(pending, op="activate", backend_port=backend.port, health_key=backend.key))
        self.assertEqual(result.get("error"), "health_failed")

    async def test_duplicate_runtime_and_unknown_residue_are_preserved(self):
        socket_inode = (self.service.runtime / "control.sock").stat().st_ino
        duplicate = relay.Relay(self.service.runtime)
        with self.assertRaisesRegex(relay.RelayError, "^runtime_busy$"):
            await duplicate.start()
        self.assertEqual((self.service.runtime / "control.sock").stat().st_ino, socket_inode)
        self.assertTrue((await self.request(b'{"op":"status"}\n'))["ok"])
        residue = self.root / "crashed-runtime"
        residue.mkdir(mode=0o700)
        unknown = socket.socket(socket.AF_UNIX)
        try:
            unknown.bind(str(residue / "control.sock"))
        finally:
            unknown.close()
        inode = (residue / "control.sock").stat().st_ino
        with self.assertRaisesRegex(relay.RelayError, "^runtime_not_clean$"):
            await relay.Relay(residue).start()
        self.assertEqual((residue / "control.sock").stat().st_ino, inode)

    async def test_unsafe_runtime_and_foreign_listener_are_not_modified(self):
        unsafe = self.root / "unsafe"
        unsafe.mkdir(mode=0o755)
        with self.assertRaisesRegex(relay.RelayError, "^runtime_unsafe$"):
            await relay.Relay(unsafe).start()
        link = self.root / "symlink"
        link.symlink_to(self.service.runtime, target_is_directory=True)
        with self.assertRaisesRegex(relay.RelayError, "^runtime_unsafe$"):
            await relay.Relay(link).start()
        backend = await self.backend()
        with self.assertRaises(OSError):
            await relay.Relay(self.root / "collision", port=backend.port).start()
        self.assertTrue(backend.server.is_serving())

    async def test_independent_helpers_and_cleanup_allow_fresh_epoch(self):
        other = await self.make_relay("other")
        first, second = await self.backend(), await self.backend()
        identity = await self.activate(first)
        await self.activate(second, service=other)
        await self.service.control(dict(identity, op="release"))
        await self.echo(other)
        old_epoch, port = self.service.epoch, self.service.port
        await self.service.close()
        self.assertFalse((self.service.runtime / "control.sock").exists())
        self.assertFalse((self.service.runtime / "ready.json").exists())
        self.assertTrue((self.service.runtime / "relay.lock").exists())
        with self.assertRaises(OSError):
            await asyncio.open_connection("127.0.0.1", port)
        replacement = relay.Relay(self.service.runtime)
        self.relays.append(replacement)
        await replacement.start()
        self.assertNotEqual(replacement.epoch, old_epoch)

    async def test_control_cli_reports_missing_runtime_without_secret_output(self):
        process = await asyncio.create_subprocess_exec(sys.executable, str(Path(relay.__file__)), "control",
            "--runtime-dir", str(self.root / "missing"), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        output, errors = await process.communicate(b'{"op":"status"}\n')
        self.assertEqual(json.loads(output).get("error"), "runtime_missing")
        self.assertEqual(errors, b"")

    async def test_control_cli_status_and_shutdown_cancel_pending_connections(self):
        process = await asyncio.create_subprocess_exec(sys.executable, str(Path(relay.__file__)), "control",
            "--runtime-dir", str(self.service.runtime), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        output, errors = await process.communicate(b'{"op":"status"}\n')
        self.assertTrue(json.loads(output)["ok"])
        self.assertEqual(process.returncode, 0)
        self.assertEqual(errors, b"")
        reader, writer = await asyncio.open_unix_connection(str(self.service.runtime / "control.sock"))
        self.writers.append(writer)
        writer.write(b'{"op":')
        await writer.drain()
        await asyncio.sleep(0.01)
        await self.service.close()
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")
        self.assertFalse(self.service.control_tasks)

    async def test_data_and_control_concurrency_are_bounded(self):
        backend = await self.backend()
        await self.activate(backend)
        with mock.patch.object(relay, "MAX_DATA", 1):
            reader, writer = await self.connect()
            writer.write(b"held\n")
            await writer.drain()
            self.assertEqual(await reader.readline(), b"held\n")
            rejected, _ = await self.connect()
            self.assertEqual(await asyncio.wait_for(rejected.read(1), 1), b"")
            self.assertLessEqual(len(self.service.data_tasks), 1)
        with mock.patch.object(relay, "MAX_CONTROL", 1):
            first, held = await asyncio.open_unix_connection(str(self.service.runtime / "control.sock"))
            self.writers.append(held)
            await asyncio.sleep(0.01)
            rejected, other = await asyncio.open_unix_connection(str(self.service.runtime / "control.sock"))
            self.writers.append(other)
            self.assertEqual(await asyncio.wait_for(rejected.read(1), 1), b"")
            self.assertLessEqual(len(self.service.control_tasks), 1)
            held.write(b'{"op":"status"}\n')
            await held.drain()
            self.assertTrue(json.loads(await first.readline())["ok"])


if __name__ == "__main__":
    unittest.main()
