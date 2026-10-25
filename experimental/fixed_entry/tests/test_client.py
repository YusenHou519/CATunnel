import asyncio
import json
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from client import ClientError, FixedEntryClient


class HelperFixture:
    """An in-memory protocol peer; never launches SSH or reads user settings."""

    def __init__(self):
        self.epoch = "fixture-epoch"
        self.generation = 0
        self.requests = []
        self.lose_begin_response = False
        self.activation_started = asyncio.Event()
        self.activation_gate = None

    async def control(self, request, timeout=8):
        self.requests.append(request.copy())
        operation = request["op"]
        if operation == "status":
            return {"ok": True, "epoch": self.epoch, "generation": self.generation,
                    "port": 18000, "lease_seconds": 20}
        if operation == "begin":
            if request["epoch"] != self.epoch or request["expected_generation"] != self.generation:
                raise ClientError("stale_generation", "Competing begin", fatal=True)
            self.generation += 1
            if self.lose_begin_response:
                raise ClientError("ssh_transport", "Response lost")
            return {"ok": True, "epoch": self.epoch, "generation": self.generation, "ticket": "a" * 64}
        if operation == "activate":
            self.activation_started.set()
            if self.activation_gate is not None:
                await self.activation_gate.wait()
            return {"ok": True, "epoch": self.epoch, "generation": self.generation,
                    "backend_port": request["backend_port"], "lease_seconds": 20}
        if operation == "release":
            return {"ok": True}
        raise AssertionError("Unexpected fixture operation")


class ClientTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ctfe-client-tests.")
        root = Path(self.directory.name)
        self.identity = root / "fixture identity"
        self.known_hosts = root / "fixture known hosts"
        self.identity.touch()
        self.known_hosts.touch()
        self.clients = []

    def client(self, **overrides):
        options = dict(host="127.0.0.1", user="fixture", ssh_port=2222,
                       identity_file=self.identity, known_hosts_file=self.known_hosts,
                       remote_helper="/tmp/fixture helper/relay.py",
                       remote_runtime="/tmp/fixture runtime", local_port=7890)
        options.update(overrides)
        instance = FixedEntryClient(**options)
        self.clients.append(instance)
        return instance

    async def asyncTearDown(self):
        for instance in self.clients:
            await instance.stop()
        self.directory.cleanup()

    def command_client(self):
        instance = self.client()
        instance._temporary = tempfile.TemporaryDirectory(prefix="ctfe-command-tests.")
        return instance

    async def test_strict_master_and_control_command_boundaries(self):
        instance = self.command_client()
        master = instance._master_arguments()
        self.assertNotIn("-R", master)
        self.assertIn("-M", master)
        for option in ("StrictHostKeyChecking=yes", "IdentitiesOnly=yes", "IdentityAgent=none",
                       "GlobalKnownHostsFile=/dev/null", "ControlPersist=no"):
            self.assertIn(option, master)
        self.assertEqual(master[master.index("-F") + 1], "/dev/null")
        self.assertEqual(master[master.index("-i") + 1], str(self.identity))
        remote = instance._remote_arguments()
        self.assertIn("ProxyCommand=/usr/bin/false", remote)
        self.assertIn("ControlMaster=no", remote)
        self.assertEqual(shlex.split(remote[-1]), ["python3", "/tmp/fixture helper/relay.py",
                                                  "control", "--runtime-dir", "/tmp/fixture runtime"])
        forward = instance._mux_arguments("forward", "-R", "127.0.0.1:0:127.0.0.1:4567")
        self.assertIn("ProxyCommand=/usr/bin/false", forward)
        self.assertEqual(forward[forward.index("-O") + 1], "forward")

    async def test_control_material_uses_stdin_only(self):
        instance = self.command_client()
        request = {"op": "activate", "ticket": "a" * 64, "health_key": "b" * 64}
        captured = []

        async def command(arguments, payload=None, timeout=8):
            captured.append((arguments, payload))
            return 0, b'{"ok":true}\n', b""

        instance._command = command
        self.assertEqual(await instance._control(request), {"ok": True})
        arguments, payload = captured[0]
        self.assertEqual(json.loads(payload), request)
        self.assertTrue(payload.endswith(b"\n"))
        for value in (request["ticket"], request["health_key"]):
            self.assertNotIn(value, " ".join(arguments))

    async def test_command_collects_fragmented_stdout_and_stderr_until_eof(self):
        instance = self.client()
        script = ("import os,time; os.write(1,b'first'); os.write(2,b'err'); "
                  "time.sleep(.03); os.write(1,b'second'); os.write(2,b'or')")
        code, output, error = await instance._command([sys.executable, "-c", script])
        self.assertEqual((code, output, error), (0, b"firstsecond", b"error"))
        self.assertFalse(instance._children)

    async def test_command_rejects_oversized_output_and_reaps_child(self):
        instance = self.client()
        with self.assertRaises(ClientError) as caught:
            await instance._command([sys.executable, "-c", "import os; os.write(1,b'x'*9000)"])
        self.assertEqual(caught.exception.code, "response_too_large")
        self.assertFalse(instance._children)

    async def test_command_timeout_reaps_child(self):
        instance = self.client()
        with self.assertRaises(ClientError) as caught:
            await instance._command([sys.executable, "-c", "import time; time.sleep(30)"], timeout=.05)
        self.assertEqual(caught.exception.code, "ssh_timeout")
        self.assertFalse(instance._children)

    async def test_nonzero_helper_json_preserves_permanent_and_transient_errors(self):
        instance = self.command_client()
        for error, fatal in (("runtime_missing", True), ("runtime_unsafe", True),
                             ("helper_unavailable", True), ("superseded", True),
                             ("stale_generation", True), ("stale_lease", False),
                             ("stale_candidate", False), ("epoch_mismatch", False),
                             ("health_failed", False)):
            with self.subTest(error=error):
                async def command(arguments, payload=None, timeout=8):
                    return 1, json.dumps({"ok": False, "error": error}).encode() + b"\n", b""

                instance._command = command
                with self.assertRaises(ClientError) as caught:
                    await instance._control({"op": "renew"})
                self.assertEqual(caught.exception.code, error)
                self.assertEqual(caught.exception.fatal, fatal)

    async def test_ssh_exit_255_remains_transport_or_identity_failure(self):
        instance = self.command_client()
        for diagnostic, expected, fatal in ((b"Connection reset", "ssh_transport", False),
                                             (b"Permission denied (publickey)", "ssh_identity", True)):
            with self.subTest(expected=expected):
                async def command(arguments, payload=None, timeout=8):
                    return 255, b'{"ok":false,"error":"runtime_missing"}\n', diagnostic

                instance._command = command
                with self.assertRaises(ClientError) as caught:
                    await instance._control({"op": "status"})
                self.assertEqual((caught.exception.code, caught.exception.fatal), (expected, fatal))

    async def test_unknown_error_and_invalid_response_do_not_echo_material(self):
        instance = self.command_client()
        opaque = "sensitive-fixture-marker"
        for code, body, expected in ((1, json.dumps({"ok": False, "error": opaque}).encode() + b"\n", "remote_failure"),
                                     (0, opaque.encode() + b"\n", "response_invalid"),
                                     (0, b'{"ok":true}\n{"ok":true}\n', "response_invalid")):
            with self.subTest(expected=expected):
                async def command(arguments, payload=None, timeout=8):
                    return code, body, b""

                instance._command = command
                with self.assertRaises(ClientError) as caught:
                    await instance._control({"op": "status"})
                self.assertEqual(caught.exception.code, expected)
                self.assertNotIn(opaque, str(caught.exception))

    async def test_missing_remote_executable_is_permanent(self):
        instance = self.command_client()

        async def command(arguments, payload=None, timeout=8):
            return 2, b"", b"python3: can't open file '/fixture/relay.py'"

        instance._command = command
        with self.assertRaises(ClientError) as caught:
            await instance._control({"op": "status"})
        self.assertEqual(caught.exception.code, "helper_missing")
        self.assertTrue(caught.exception.fatal)

    async def test_newer_generation_after_transport_loss_cannot_be_taken_back(self):
        instance, helper = self.client(), HelperFixture()
        instance._control = helper.control
        await instance._establish_lease(20000, b"x" * 32)
        await instance._cleanup()
        helper.generation += 1
        helper.requests.clear()
        with self.assertRaises(ClientError) as caught:
            await instance._establish_lease(20001, b"y" * 32)
        self.assertEqual(caught.exception.code, "superseded")
        self.assertTrue(caught.exception.fatal)
        self.assertEqual([item["op"] for item in helper.requests], ["status"])
        self.assertFalse(instance.connected)

    async def test_same_generation_transport_reconnect_gets_new_lease(self):
        events = []
        instance, helper = self.client(on_event=events.append), HelperFixture()
        instance._control = helper.control
        await instance._establish_lease(20000, b"x" * 32)
        await instance._cleanup()
        self.assertIsNone(instance.backend_port)
        seconds = await instance._establish_lease(20001, b"y" * 32)
        self.assertEqual(seconds, 20)
        self.assertEqual(helper.generation, 2)
        self.assertTrue(instance.connected)
        self.assertEqual(instance.backend_port, 20001)
        self.assertEqual([event["generation"] for event in events], [1, 2])
        self.assertNotIn("ticket", json.dumps(events))
        self.assertNotIn("health_key", json.dumps(events))

    async def test_new_daemon_epoch_can_recover(self):
        instance, helper = self.client(), HelperFixture()
        instance._control = helper.control
        await instance._establish_lease(20000, b"x" * 32)
        await instance._cleanup()
        helper.epoch, helper.generation = "replacement-epoch", 0
        await instance._establish_lease(20001, b"y" * 32)
        self.assertEqual(instance._generation_guard, ("replacement-epoch", 1))

    async def test_lost_begin_response_cannot_blindly_claim_later_generation(self):
        instance, helper = self.client(), HelperFixture()
        instance._control = helper.control
        helper.lose_begin_response = True
        with self.assertRaises(ClientError):
            await instance._establish_lease(20000, b"x" * 32)
        await instance._cleanup()
        helper.lose_begin_response = False
        helper.requests.clear()
        with self.assertRaises(ClientError) as caught:
            await instance._establish_lease(20001, b"y" * 32)
        self.assertEqual(caught.exception.code, "superseded")
        self.assertEqual([item["op"] for item in helper.requests], ["status"])

    async def test_cancel_activation_keeps_identity_for_best_effort_release(self):
        instance, helper = self.client(), HelperFixture()
        instance._control = helper.control
        instance._master = SimpleNamespace(returncode=None)
        helper.activation_gate = asyncio.Event()
        activation = asyncio.create_task(instance._establish_lease(20000, b"x" * 32))
        await asyncio.wait_for(helper.activation_started.wait(), 1)
        activation.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await activation
        self.assertEqual(instance._lease["generation"], 1)
        await instance._cleanup()
        self.assertEqual(helper.requests[-1], {"op": "release", "epoch": helper.epoch,
                                               "generation": 1, "ticket": "a" * 64})
        self.assertIsNone(instance._lease)

    async def test_fatal_superseded_run_does_not_retry(self):
        events = []
        instance, helper = self.client(on_event=events.append), HelperFixture()
        instance._control = helper.control
        instance._generation_guard = (helper.epoch, 1)
        helper.generation = 2

        async def connect():
            return await instance._establish_lease(20000, b"x" * 32)

        instance._connect = connect
        with self.assertRaises(ClientError) as caught:
            await instance.run()
        self.assertEqual(caught.exception.code, "superseded")
        self.assertEqual([item["op"] for item in helper.requests], ["status"])
        self.assertNotIn("retrying", [item["event"] for item in events])
        self.assertEqual(events[-1]["event"], "stopped")

    async def test_stop_during_retry_wait_prevents_another_attempt(self):
        retrying = asyncio.Event()
        events = []

        def event(value):
            events.append(value)
            if value["event"] == "retrying":
                retrying.set()

        instance = self.client(on_event=event)
        attempts = []

        async def connect():
            attempts.append(1)
            raise ClientError("ssh_transport", "Fixture transport lost")

        instance._connect = connect
        running = asyncio.create_task(instance.run())
        await asyncio.wait_for(retrying.wait(), 1)
        await instance.stop()
        await running
        self.assertEqual(len(attempts), 1)
        self.assertEqual([item["event"] for item in events].count("stopped"), 1)

    async def test_concurrent_stop_reaps_only_owned_child(self):
        instance = self.client()
        ready = asyncio.Event()
        children = []
        foreign = await asyncio.create_subprocess_exec(sys.executable, "-c", "import time; time.sleep(30)",
                                                       stdin=asyncio.subprocess.DEVNULL,
                                                       stdout=asyncio.subprocess.DEVNULL,
                                                       stderr=asyncio.subprocess.DEVNULL)

        async def connect():
            child = await instance._spawn([sys.executable, "-c", "import time; time.sleep(30)"],
                                          stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
                                          stderr=asyncio.subprocess.DEVNULL)
            children.append(child)
            ready.set()
            await child.wait()

        instance._connect = connect
        running = asyncio.create_task(instance.run())
        try:
            await asyncio.wait_for(ready.wait(), 1)
            await asyncio.gather(instance.stop(), instance.stop())
            await running
            self.assertIsNotNone(children[0].returncode)
            self.assertIsNone(foreign.returncode)
            self.assertFalse(instance._children)
            self.assertIsNone(instance.master_pid)
            self.assertIsNone(instance.gateway_port)
            self.assertIsNone(instance.control_directory)
        finally:
            if foreign.returncode is None:
                foreign.terminate()
            await foreign.wait()

    async def test_stop_before_run_and_repeated_stop_are_idempotent(self):
        events = []
        instance = self.client(on_event=events.append)
        await instance.stop()
        await instance.stop()
        await instance.run()
        self.assertEqual(events, [{"event": "stopped"}])
        with self.assertRaises(RuntimeError):
            await instance.run()

    async def test_observations_are_read_only(self):
        instance = self.client()
        for name in ("master_pid", "connected", "backend_port", "gateway_port", "control_directory"):
            with self.subTest(name=name), self.assertRaises(AttributeError):
                setattr(instance, name, None)


if __name__ == "__main__":
    unittest.main()
