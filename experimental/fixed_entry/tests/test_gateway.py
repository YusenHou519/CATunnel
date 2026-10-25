import asyncio
import hashlib
import hmac
from pathlib import Path
import secrets
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gateway


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.servers, self.gateways, self.writers = [], [], []
        self.proxy_tasks, self.proxy_writers = set(), set()
        self.proxy_connections = 0
        self.key = secrets.token_bytes(32)

    async def asyncTearDown(self):
        for instance in self.gateways:
            await instance.stop()
        for writer in self.writers:
            await gateway.close_writer(writer)
        for server in self.servers:
            server.close()
            await server.wait_closed()
        for writer in self.proxy_writers:
            writer.close()
        tasks = tuple(self.proxy_tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    async def proxy(self, handler=None):
        async def echo(reader, writer):
            while True:
                data = await reader.read(16384)
                if not data:
                    return
                writer.write(data)
                await writer.drain()

        async def serve(reader, writer):
            self.proxy_connections += 1
            try:
                await (handler or echo)(reader, writer)
            except (OSError, asyncio.CancelledError):
                pass
            finally:
                writer.close()
                await gateway.close_writer(writer)
                self.proxy_writers.discard(writer)

        def accept(reader, writer):
            self.proxy_writers.add(writer)
            task = asyncio.create_task(serve(reader, writer))
            self.proxy_tasks.add(task)

            def finished(completed):
                self.proxy_tasks.discard(completed)
                writer.close()

            task.add_done_callback(finished)

        server = await asyncio.start_server(accept, "127.0.0.1", 0)
        self.servers.append(server)
        return server

    async def start_gateway(self, proxy, **options):
        instance = gateway.Gateway(proxy.sockets[0].getsockname()[1], self.key, **options)
        self.gateways.append(instance)
        await instance.start()
        return instance

    async def connect(self, instance):
        reader, writer = await asyncio.open_connection("127.0.0.1", instance.port)
        self.writers.append(writer)
        return reader, writer

    async def test_health_hmac_requires_a_live_loopback_proxy(self):
        proxy = await self.proxy()
        instance = await self.start_gateway(proxy)
        self.assertEqual(instance._server.sockets[0].getsockname()[0], "127.0.0.1")
        challenge = secrets.token_hex(32).encode("ascii")
        reader, writer = await self.connect(instance)
        writer.write(gateway.HEALTH_PREFIX + challenge + b"\n")
        await writer.drain()
        response = await asyncio.wait_for(reader.readline(), 1)
        proof = hmac.new(self.key, challenge, hashlib.sha256).hexdigest().encode("ascii")
        self.assertTrue(hmac.compare_digest(response, gateway.HEALTH_PREFIX + proof + b"\n"),
                        "Gateway returned an incorrect health proof")
        self.assertEqual(self.proxy_connections, 1)
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")

    async def test_health_fails_when_local_proxy_is_unavailable(self):
        proxy = await self.proxy()
        instance = await self.start_gateway(proxy)
        proxy.close()
        await proxy.wait_closed()
        reader, writer = await self.connect(instance)
        writer.write(gateway.HEALTH_PREFIX + secrets.token_hex(32).encode("ascii") + b"\n")
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
        self.assertEqual(self.proxy_connections, 0)

    async def test_fragmented_http_connect_and_socks_bytes_are_unchanged(self):
        proxy = await self.proxy()
        instance = await self.start_gateway(proxy)
        payloads = [b"CONNECT fixture.invalid:443 HTTP/1.1\r\nHost: fixture.invalid\r\n\r\n\x00\xffbody",
                    b"\x05\x01\x00\x05\x01\x00\x03\x07fixture\x01\xbb\x00\xff"]
        for payload in payloads:
            reader, writer = await self.connect(instance)
            for offset in range(0, len(payload), 2):
                writer.write(payload[offset:offset + 2])
                await writer.drain()
                await asyncio.sleep(0)
            received = await asyncio.wait_for(reader.readexactly(len(payload)), 1)
            self.assertTrue(received == payload, "Fragmented proxy traffic was consumed or rewritten")
            await gateway.close_writer(writer)
        self.assertEqual(self.proxy_connections, 2)

    async def test_malformed_and_unknown_health_requests_fail_closed(self):
        proxy = await self.proxy()
        instance = await self.start_gateway(proxy)
        requests = [b"CATUNNEL-HEALTH-2 " + b"0" * 64 + b"\n",
                    b"CATUNNEL-HEALTH-1 invalid\n", b"CATUNNEL-" + b"x" * 160]
        for request in requests:
            reader, writer = await self.connect(instance)
            writer.write(request)
            await writer.drain()
            try:
                response = await asyncio.wait_for(reader.read(), 1)
            except ConnectionResetError:
                response = b""
            self.assertEqual(response, b"")
        self.assertEqual(self.proxy_connections, 0)

    async def test_tcp_half_close_preserves_the_reverse_response(self):
        async def reply_after_eof(reader, writer):
            data = await reader.read()
            writer.write(b"response:" + data)
            await writer.drain()

        proxy = await self.proxy(reply_after_eof)
        instance = await self.start_gateway(proxy)
        reader, writer = await self.connect(instance)
        writer.write(b"GET /fixture\r\nbody")
        await writer.drain()
        writer.write_eof()
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"response:GET /fixture\r\nbody")

    async def test_reverse_activity_extends_shared_idle_deadline_then_idle_closes(self):
        async def periodic_reply(reader, writer):
            await reader.readexactly(1)
            for _ in range(6):
                await asyncio.sleep(0.05)
                writer.write(b"tick")
                await writer.drain()
            await reader.read()

        proxy = await self.proxy(periodic_reply)
        instance = await self.start_gateway(proxy, idle_timeout=0.2)
        reader, writer = await self.connect(instance)
        writer.write(b"G")
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.readexactly(24), 2), b"tick" * 6)
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")

    async def test_stop_closes_active_and_partial_prefix_connections_and_caps_concurrency(self):
        proxy = await self.proxy()
        instance = await self.start_gateway(proxy, max_connections=2)
        port = instance.port
        reader, writer = await self.connect(instance)
        writer.write(b"GET /held\n")
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.readline(), 1), b"GET /held\n")
        partial, partial_writer = await self.connect(instance)
        partial_writer.write(b"C")
        await partial_writer.drain()
        await asyncio.sleep(0.01)
        rejected, _ = await self.connect(instance)
        self.assertEqual(await asyncio.wait_for(rejected.read(1), 1), b"")
        self.assertLessEqual(len(instance._tasks), 2)
        await instance.stop()
        await instance.stop()
        self.assertEqual(await asyncio.wait_for(reader.read(1), 1), b"")
        self.assertEqual(await asyncio.wait_for(partial.read(1), 1), b"")
        self.assertFalse(instance._tasks)
        self.assertFalse(instance._writers)
        with self.assertRaises(OSError):
            await asyncio.open_connection("127.0.0.1", port)

    async def test_gateway_rejects_its_own_port_as_proxy_destination(self):
        instance = gateway.Gateway(34567, self.key)
        self.gateways.append(instance)
        server = mock.Mock()
        server.sockets = [mock.Mock()]
        server.sockets[0].getsockname.return_value = ("127.0.0.1", 34567)
        server.wait_closed = mock.AsyncMock()
        with mock.patch.object(gateway.asyncio, "start_server", new=mock.AsyncMock(return_value=server)):
            with self.assertRaisesRegex(ValueError, "conflicts"):
                await instance.start()
        server.close.assert_called_once()
        server.wait_closed.assert_awaited_once()
        self.assertIsNone(instance.port)


if __name__ == "__main__":
    unittest.main()
