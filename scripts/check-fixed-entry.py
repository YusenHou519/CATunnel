#!/usr/bin/env python3
"""Real-SSH fixed-entry prototype check using only disposable loopback services.

Run: python3 scripts/check-fixed-entry.py --output /path/to/report.json
No production settings, keys, servers, installed app, or public network is used.
"""

import argparse
import asyncio
import importlib.util
import json
import os
import pathlib
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY))
_spec = importlib.util.spec_from_file_location("fixed_entry_fixture", pathlib.Path(__file__).with_name("fixtures") / "fixed_entry_fixture.py")
fixture_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fixture_module)


class CheckRun:
    def __init__(self):
        self.started = time.monotonic()
        self.lock = threading.Lock()
        self.fixture = None
        self.binary = None
        self.clients, self.tasks = [], []
        self.health_task = None
        self.expected_stopped = set()
        self.next_capture = 0
        self.report = {"suite": "fixed-entry-real-ssh", "status": "failed", "checks": [], "timeline": [],
                       "limits": ["Disposable macOS sshd and exact local HTTP markers only; no public egress test.",
                                  "Relay TCP ACKs remain active while SSH application bytes are discarded.",
                                  "Fault injection terminates only the fixture's verified client SSH master; timers are unchanged.",
                                  "No physical sleep/wake, production server deployment, or installed GUI validation."]}

    def record(self, kind, **fields):
        item = {"type": kind, "elapsed": round(time.monotonic() - self.started, 3), **fields}
        with self.lock:
            self.report["timeline"].append(item)
        if kind in {"stage", "check", "fault-owned-client-master", "relay-blackhole"}:
            print(json.dumps(item, ensure_ascii=False), flush=True)

    def check(self, name, passed, detail=None):
        self.report["checks"].append({"name": name, "passed": bool(passed), "detail": detail})
        self.record("check", name=name, passed=bool(passed))
        if not passed:
            raise RuntimeError(name)

    def client_event(self, index, event):
        # The callback contract is non-secret. Retain only fields useful for this report.
        allowed = {key: value for key, value in event.items()
                   if key in {"event", "type", "entry_port", "backend_port", "generation", "delay_seconds", "reason", "message"}}
        self.record("client-event", client=index, event=allowed)

    async def capture(self):
        if time.monotonic() >= self.next_capture:
            for client in self.clients:
                self.fixture.remember_client(client)
            self.next_capture = time.monotonic() + 0.5

    async def wait(self, predicate, timeout, label):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            await self.capture()
            for index, task in enumerate(self.tasks):
                if index not in self.expected_stopped and task.done():
                    error = None if task.cancelled() else task.exception()
                    raise RuntimeError(f"Fixture client {index} stopped unexpectedly: {error}")
            if self.health_task is not None and self.health_task.done():
                await self.health_task
                raise RuntimeError("Independent healthy control monitor exited early")
            if self.fixture.relay.errors:
                raise RuntimeError("Fixture byte relay failed: " + str(self.fixture.relay.errors))
            if predicate():
                return
            await asyncio.sleep(0.05)
        raise TimeoutError(label)

    async def request(self, port):
        process = await asyncio.create_subprocess_exec(
            "/usr/bin/curl", "-q", "--silent", "--show-error", "--fail", "--noproxy", "*", "--proxy", "",
            "--connect-timeout", "1", "--max-time", "3", f"http://127.0.0.1:{port}/fixed-entry-marker",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            stdout, _ = await asyncio.wait_for(process.communicate(), timeout=4)
            return process.returncode, stdout
        finally:
            if process.returncode is None:
                process.terminate()
                await process.wait()

    async def exact_transfer(self, index):
        port = self.fixture.entry_ready[index]["port"]
        code, body = await self.request(port)
        passed = code == 0 and body == self.markers[index].encode()
        self.record("exact-transfer", client=index, passed=passed, exit_code=code)
        if not passed:
            raise RuntimeError(f"Fixed entry {index} failed its exact HTTP marker transfer: curl exit {code}")

    async def health_monitor(self):
        while True:
            await self.exact_transfer(1)
            await asyncio.sleep(2)

    async def status(self, index):
        process = await asyncio.create_subprocess_exec(
            sys.executable, str(self.fixture.helper_path), "control", "--runtime-dir", str(self.fixture.runtimes[index]),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            stdout, _ = await asyncio.wait_for(process.communicate(b'{"op":"status"}\n'), timeout=5)
            if process.returncode != 0:
                raise RuntimeError("Fixture helper status command failed")
            response = json.loads(stdout)
            if response.get("ok") is not True:
                raise RuntimeError("Fixture helper refused status")
            return response
        finally:
            if process.returncode is None:
                process.terminate()
                await process.wait()

    async def exercise(self, client_class):
        fixture = self.fixture
        for index in range(2):
            client = client_class(host="127.0.0.1", user=fixture.user, ssh_port=fixture.ssh_ports[index],
                                  identity_file=str(fixture.root / "client"), known_hosts_file=str(fixture.root / "known_hosts"),
                                  remote_helper=str(fixture.helper_path), remote_runtime=str(fixture.runtimes[index]),
                                  local_port=fixture.servers[index].server_port,
                                  on_event=lambda event, index=index: self.client_event(index, event))
            self.clients.append(client)
            self.tasks.append(asyncio.create_task(client.run()))
        await self.wait(lambda: all(client.connected and client.backend_port is not None for client in self.clients),
                        45, "Both fixed-entry clients did not connect")
        for index in range(2):
            await self.exact_transfer(index)
        await self.wait(lambda: len(fixture.relay.active()) == 1, 5, "Expected one established A transport")
        self.health_task = asyncio.create_task(self.health_monitor())
        fixed = [await asyncio.to_thread(fixture_module.listener_owner, item["port"], None, fixture.helpers[index].pid)
                 for index, item in enumerate(fixture.entry_ready)]
        self.check("each fixed listener belongs to its independent helper process", all(fixed), fixed)
        old_port = self.clients[0].backend_port
        old_owner = await asyncio.to_thread(fixture_module.listener_owner, old_port, fixture.sshds[0].pid)
        self.check("old dynamic backend is a real owned sshd listener", old_owner is not None, old_owner)
        old_master = self.clients[0].master_pid
        healthy_master, healthy_backend = self.clients[1].master_pid, self.clients[1].backend_port
        healthy_status = await self.status(1)
        frozen = fixture.relay.active()[0]
        self.record("stage", message="Retaining the old server transport while terminating only its owned client master")
        frozen.freeze()
        await asyncio.to_thread(fixture.fault_owned_master, old_master)
        await self.wait(lambda: self.clients[0].connected and self.clients[0].backend_port not in (None, old_port)
                        and self.clients[0].master_pid not in (None, old_master),
                        60, "Client did not recover automatically through a new dynamic forward")
        await self.wait(lambda: frozen.state()["frontEOF"], 5, "Frozen relay did not observe the dead client's EOF")
        new_port = self.clients[0].backend_port
        retained = await asyncio.to_thread(fixture_module.listener_owner, old_port, fixture.sshds[0].pid)
        new_owner = await asyncio.to_thread(fixture_module.listener_owner, new_port, fixture.sshds[0].pid)
        self.check("old dynamic listener stays owned by the same sshd after client loss",
                   retained == old_owner and not frozen.state()["backendEOF"], frozen.state())
        self.check("automatic recovery allocates a different real SSH backend without removing the old one",
                   new_port != old_port and new_owner is not None and new_owner != old_owner,
                   {"old_port": old_port, "new_port": new_port, "old_owner": old_owner, "new_owner": new_owner})
        for index in range(2):
            current = await asyncio.to_thread(fixture_module.listener_owner, fixture.entry_ready[index]["port"],
                                              None, fixture.helpers[index].pid)
            self.check(f"fixed entry {index} retains the same PID and port", current == fixed[index])
            await self.exact_transfer(index)
        current_status = await self.status(0)
        self.check("the unchanged fixed entry actively selects the new backend", current_status["backend_port"] == new_port)
        healthy_after = await self.status(1)
        self.check("independent entry and healthy SSH transport are unaffected",
                   self.clients[1].master_pid == healthy_master and self.clients[1].backend_port == healthy_backend
                   and healthy_after["active_generation"] == healthy_status["active_generation"]
                   and healthy_after["backend_port"] == healthy_status["backend_port"])
        self.report["recovery"] = {"fixed_entry_port": fixture.entry_ready[0]["port"],
                                   "fixed_entry_pid": fixture.helpers[0].pid, "old_backend_port": old_port,
                                   "new_backend_port": new_port, "old_sshd_pid": old_owner["pid"],
                                   "new_sshd_pid": new_owner["pid"]}
        self.record("stage", message="Fixed entry recovered with the old listener intact; checking explicit stop")
        self.expected_stopped.add(0)
        await asyncio.wait_for(self.clients[0].stop(), timeout=12)
        await asyncio.wait_for(self.tasks[0], timeout=5)
        attempts = fixture.relay.count()
        await asyncio.sleep(2)
        self.check("explicit stop completes without reconnecting", not self.clients[0].connected and fixture.relay.count() == attempts)
        stopped_status = await self.status(0)
        before = time.monotonic()
        code, _ = await self.request(fixture.entry_ready[0]["port"])
        self.check("stopped fixed entry stays listening and fails promptly with no active backend",
                   stopped_status["backend_port"] is None and code != 0 and time.monotonic() - before < 3)
        await self.exact_transfer(1)
        retained = await asyncio.to_thread(fixture_module.listener_owner, old_port, fixture.sshds[0].pid)
        self.check("stopping the new generation does not kill the retained old sshd listener", retained == old_owner)
        if self.health_task.done():
            await self.health_task
        with self.lock:
            healthy_transfers = [item for item in self.report["timeline"]
                                 if item["type"] == "exact-transfer" and item["client"] == 1]
        self.check("all independent healthy-control marker observations succeeded",
                   len(healthy_transfers) >= 2 and all(item["passed"] for item in healthy_transfers),
                   {"observations": len(healthy_transfers)})
        self.report["status"] = "passed"

    async def stop_runner(self):
        pass

    async def run(self):
        temporary_path = None
        loop = asyncio.get_running_loop()
        current = asyncio.current_task()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, current.cancel)
        try:
            if sys.platform != "darwin":
                raise RuntimeError("The real-SSH fixture currently requires macOS")
            for executable in ("/usr/sbin/sshd", "/usr/bin/ssh", "/usr/bin/ssh-keygen", "/usr/sbin/lsof", "/usr/bin/curl"):
                if not os.access(executable, os.X_OK):
                    raise RuntimeError(f"Required executable is unavailable: {executable}")
            FixedEntryClient = None
            if self.binary is None:
                from experimental.fixed_entry.client import FixedEntryClient
            elif not os.access(self.binary, os.X_OK):
                raise RuntimeError("The Swift integration runner is not executable")
            base = pathlib.Path(os.environ.get("TMPDIR", "")).resolve()
            metadata = base.stat()
            if not os.environ.get("TMPDIR") or metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
                raise RuntimeError("TMPDIR must be the current user's private temporary directory")
            with tempfile.TemporaryDirectory(prefix="catf.", dir=base) as directory:
                temporary_path = pathlib.Path(directory).resolve()
                temporary_path.chmod(0o700)
                self.fixture = fixture_module.SSHFixture(temporary_path, REPOSITORY / "experimental/fixed_entry/relay.py", self.record)
                self.markers = ["catunnel-fixed-entry-" + secrets.token_hex(12) for _ in range(2)]
                try:
                    self.record("stage", message="Starting isolated helpers, strict-key SSH services, and local markers")
                    await asyncio.to_thread(self.fixture.setup, self.markers, self.binary is not None)
                    await self.exercise(FixedEntryClient)
                finally:
                    if self.health_task is not None:
                        self.health_task.cancel()
                        await asyncio.gather(self.health_task, return_exceptions=True)
                    cleanup_errors = []
                    try:
                        await self.stop_runner()
                    except (Exception, asyncio.CancelledError) as error:
                        cleanup_errors.append(str(error) or type(error).__name__)
                    for client in self.clients:
                        try:
                            self.fixture.remember_client(client)
                            await asyncio.wait_for(client.stop(), timeout=12)
                        except (Exception, asyncio.CancelledError) as error:
                            cleanup_errors.append(str(error) or type(error).__name__)
                    for task in self.tasks:
                        try:
                            await asyncio.wait_for(task, timeout=5)
                        except (Exception, asyncio.CancelledError) as error:
                            cleanup_errors.append(str(error) or type(error).__name__)
                    cleanup = await asyncio.to_thread(self.fixture.cleanup)
                    cleanup["errors"].extend(cleanup_errors)
                    self.report["cleanup"] = cleanup
                    for name, passed in cleanup.items():
                        if name != "errors":
                            self.report["checks"].append({"name": name, "passed": passed})
                    if cleanup["errors"] or not all(value for key, value in cleanup.items() if key != "errors"):
                        self.report["status"] = "failed"
                    self.report["serviceLogs"] = {path.name: path.read_text(errors="replace")[-4000:].replace(str(temporary_path), "<fixture>")
                                                  for path in temporary_path.glob("*.log")}
        except BaseException as error:
            self.report["status"] = "failed"
            self.report["error"] = str(error) or type(error).__name__
            self.record("stage", message="Fixture failed", error=self.report["error"])
        finally:
            for sig in (signal.SIGINT, signal.SIGTERM):
                loop.remove_signal_handler(sig)
        self.report["temporaryFixtureRemoved"] = temporary_path is None or not temporary_path.exists()
        if not self.report["temporaryFixtureRemoved"]:
            self.report["status"] = "failed"
        self.report["durationSeconds"] = round(time.monotonic() - self.started, 3)
        return self.report


class SwiftCheckRun(CheckRun):
    """The Python side supplies environment and observations, never a client or a fake Swift status."""
    def __init__(self, binary):
        super().__init__()
        self.binary = binary
        self.runner = None
        self.events, self.phases = [], {}
        self.event_offset = 0
        self.report["suite"] = "fixed-entry-swift-controller-real-ssh"
        self.report["swiftEvents"] = self.events
        self.report["sleepWakeCycles"] = []
        self.report["limits"].append("Sleep/wake invokes actual Controller lifecycle APIs, not physical system sleep or OS notifications.")
        self.report["limits"].append("Blackhole sleep checks retain remote SSH listeners, use the real 20-second lease, and measure local fixture recovery rather than physical Mac wake time.")

    def read_events(self, strict=True):
        path = self.fixture.root / "events.jsonl"
        if not path.exists():
            return
        with path.open() as stream:
            stream.seek(self.event_offset)
            while True:
                line = stream.readline()
                if not line or not line.endswith("\n"):
                    break
                self.event_offset = stream.tell()
                event = json.loads(line)
                self.events.append(event)
                if event.get("type") == "status":
                    self.phases[event["id"]] = event["phase"]
                if event.get("type") == "directory":
                    self.fixture.control_directories.add(pathlib.Path(event["path"]))
                if strict and event.get("type") == "error":
                    raise RuntimeError("Swift runner failed: " + event.get("message", "unknown failure"))

    def action(self, action, identity="all"):
        with (self.fixture.root / "actions.jsonl").open("a") as stream:
            stream.write(json.dumps({"action": action, "id": identity}) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        self.record("swift-action", action=action, id=identity)

    def master_pids(self, ssh_port=None, legacy=None):
        if self.runner is None:
            return []
        table = fixture_module.process_table()
        result = []
        for pid in fixture_module.descendants(table, self.runner.pid):
            if pathlib.Path(table[pid]["command"]).name != "ssh":
                continue
            command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                                     capture_output=True, text=True, timeout=3).stdout
            if "UserKnownHostsFile=" + str(self.fixture.root / "known_hosts") not in command:
                continue
            if not re.search(r"(?:^|\s)-M(?:\s|$)", command) or not re.search(r"(?:^|\s)-N(?:\s|$)", command):
                continue
            if ssh_port is not None and not re.search(r"(?:^|\s)-p\s+" + str(ssh_port) + r"(?:\s|$)", command):
                continue
            has_forward = re.search(r"(?:^|\s)-R(?:\s|$)", command) is not None
            if legacy is not None and has_forward != legacy:
                continue
            result.append(pid)
        return result

    async def capture(self):
        self.read_events()
        if time.monotonic() < self.next_capture or self.runner is None:
            return
        self.fixture.capture_owned()
        self.fixture.ports.update(self.gateway_ports())
        self.next_capture = time.monotonic() + 0.5

    def gateway_ports(self):
        if self.runner is None:
            return set()
        result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(self.runner.pid),
                                 "-iTCP", "-sTCP:LISTEN", "-Fn"], capture_output=True, text=True, timeout=3)
        if result.returncode not in (0, 1):
            raise RuntimeError("Cannot inspect Swift-owned fixture gateway listeners")
        ports = set()
        for line in result.stdout.splitlines():
            if line.startswith("n"):
                match = re.fullmatch(r"n127\.0\.0\.1:(\d+)", line)
                if match is None:
                    raise RuntimeError("Swift gateway opened a listener outside IPv4 loopback")
                ports.add(int(match.group(1)))
        return ports

    async def wait(self, predicate, timeout, label):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            await self.capture()
            if self.runner.poll() is not None:
                raise RuntimeError(f"Swift runner exited early with code {self.runner.returncode}")
            if self.health_task is not None and self.health_task.done():
                await self.health_task
                raise RuntimeError("Independent healthy control monitor exited early")
            if self.fixture.relay.errors:
                raise RuntimeError("Fixture byte relay failed: " + str(self.fixture.relay.errors))
            if predicate():
                return
            await asyncio.sleep(0.05)
        raise TimeoutError(label)

    async def quiet(self, seconds, predicate, label):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            await self.capture()
            if not predicate():
                raise RuntimeError(label)
            await asyncio.sleep(0.1)
        self.check(label, True, {"observed_seconds": seconds})

    async def legacy_transfer(self):
        code, body = await self.request(self.fixture.legacy_port)
        self.check("default legacy mode transfers its exact marker through the configured fixed SSH forward",
                   code == 0 and body == self.markers[1].encode())

    async def exercise(self, _client_class):
        fixture = self.fixture
        self.runner = fixture.spawn([str(self.binary), str(fixture.root / "fixture.json")], "swift-runner.log")
        await self.wait(lambda: all(self.phases.get(identity) == "connected" for identity in ("fixed-a", "fixed-b", "legacy")),
                        35, "The actual Swift controller did not connect both fixed entries and the legacy profile")
        for index in range(2):
            await self.exact_transfer(index)
        await self.legacy_transfer()
        self.check("an old JSON profile defaults to the real legacy controller branch",
                   any(item.get("type") == "legacy-default" and item.get("useFixedEntry") is False for item in self.events)
                   and len(self.master_pids(fixture.ssh_ports[1], legacy=True)) == 1)
        self.check("the two native fixed-entry profiles own exactly two IPv4 loopback gateways", len(self.gateway_ports()) == 2)
        await self.wait(lambda: len(fixture.relay.active()) == 1, 5, "Expected one Swift-owned A transport")
        self.health_task = asyncio.create_task(self.health_monitor())
        entries = [await self.status(index) for index in range(2)]
        old_port = entries[0]["backend_port"]
        fixture.ports.update(item["backend_port"] for item in entries)
        old_owner = await asyncio.to_thread(fixture_module.listener_owner, old_port, fixture.sshds[0].pid)
        self.check("the initial dynamic forward is owned by a real fixture sshd", old_owner is not None, old_owner)
        masters = self.master_pids(fixture.ssh_ports[0], legacy=False)
        self.check("the fault target is one private SSH master descended from the real Swift runner", len(masters) == 1)
        fixed_owners = [await asyncio.to_thread(fixture_module.listener_owner, item["port"], None, fixture.helpers[index].pid)
                        for index, item in enumerate(entries)]
        self.check("both fixed entries belong to their fixture helper PIDs", all(fixed_owners))
        healthy_master = self.master_pids(fixture.ssh_ports[1], legacy=False)
        frozen = fixture.relay.active()[0]
        event_start = len(self.events)
        self.record("stage", message="Faulting the Swift controller's SSH transport while retaining the old server dynamic listener")
        frozen.freeze()
        await asyncio.to_thread(fixture.fault_owned_master, masters[0])
        await self.wait(lambda: any(item.get("type") == "status" and item.get("id") == "fixed-a"
                                   and item.get("phase") == "connected" for item in self.events[event_start:]),
                        35, "Swift did not automatically recover the fixed entry")
        recovered = await self.status(0)
        new_port = recovered["backend_port"]
        fixture.ports.add(new_port)
        await self.wait(lambda: frozen.state()["frontEOF"], 5, "Old client EOF was not observed")
        retained = await asyncio.to_thread(fixture_module.listener_owner, old_port, fixture.sshds[0].pid)
        new_owner = await asyncio.to_thread(fixture_module.listener_owner, new_port, fixture.sshds[0].pid)
        self.check("Swift reconnects to a different dynamic backend while the old sshd listener remains unchanged",
                   retained == old_owner and not frozen.state()["backendEOF"] and new_port != old_port
                   and new_owner is not None and new_owner != old_owner,
                   {"old_port": old_port, "new_port": new_port, "old_owner": old_owner, "new_owner": new_owner})
        for index in range(2):
            owner = await asyncio.to_thread(fixture_module.listener_owner, entries[index]["port"], None, fixture.helpers[index].pid)
            self.check(f"Swift recovery keeps fixed entry {index}'s PID and port unchanged", owner == fixed_owners[index])
            await self.exact_transfer(index)
        healthy = await self.status(1)
        self.check("the independent native fixed entry is unchanged during A recovery",
                   healthy["backend_port"] == entries[1]["backend_port"]
                   and healthy["active_generation"] == entries[1]["active_generation"]
                   and self.master_pids(fixture.ssh_ports[1], legacy=False) == healthy_master)
        await self.legacy_transfer()
        self.report["recovery"] = {"fixed_entry_port": entries[0]["port"], "fixed_entry_pid": fixed_owners[0]["pid"],
                                   "old_backend_port": old_port, "new_backend_port": new_port,
                                   "old_sshd_pid": old_owner["pid"], "new_sshd_pid": new_owner["pid"]}
        await self.error_cases()
        self.action("stop", "fixed-a")
        await self.wait(lambda: self.phases.get("fixed-a") == "stopped" and not self.master_pids(fixture.ssh_ports[0]),
                        10, "Swift user stop did not remove A's owned master")
        self.check("stopping A closes its native gateway while retaining B's", len(self.gateway_ports()) == 1)
        attempts = fixture.relay.count()
        await self.quiet(2, lambda: self.phases.get("fixed-a") == "stopped" and fixture.relay.count() == attempts,
                         "Swift user stop cancels native fixed-entry recovery")
        await self.exact_transfer(1)
        await self.legacy_transfer()
        stopped = await self.status(0)
        self.check("Swift stop releases only its active helper lease", stopped["backend_port"] is None)
        retained = await asyncio.to_thread(fixture_module.listener_owner, old_port, fixture.sshds[0].pid)
        self.check("Swift stop leaves the retained old sshd session intact", retained == old_owner)
        if self.health_task.done():
            await self.health_task
        self.health_task.cancel()
        await asyncio.gather(self.health_task, return_exceptions=True)
        self.health_task = None
        await self.retained_sleep_cases(old_port, old_owner, frozen, fixed_owners[0], entries[0]["epoch"])
        await self.lifecycle_cases()
        self.report["status"] = "passed"

    async def retained_sleep_cases(self, original_port, original_owner, original_pair, fixed_owner, epoch):
        fixture = self.fixture
        retained = [{"port": original_port, "owner": original_owner, "pair": original_pair}]

        async def listener(port, helper=False):
            return await asyncio.to_thread(fixture_module.listener_owner, port,
                                          None if helper else fixture.sshds[0].pid,
                                          fixture.helpers[0].pid if helper else None)

        async def check_retained(label):
            observations = []
            for item in retained:
                owner = await listener(item["port"])
                state = item["pair"].state()
                observations.append({"port": item["port"], "owner": owner, "relay": state,
                                     "passed": owner == item["owner"] and state["frozen"] and not state["backendEOF"]})
            self.check(label, all(item["passed"] for item in observations), observations)

        for label, long_sleep in [("short-sleep", False), ("expired-lease-sleep", True)]:
            self.action("start", "fixed-a")
            await self.wait(lambda: self.phases.get("fixed-a") == "connected", 20,
                            label + ": fixed entry did not connect before sleep")
            await self.exact_transfer(0)
            await check_retained(label + ": earlier abandoned listeners remain before sleep")
            before = await self.status(0)
            old_port = before["backend_port"]
            old_owner = await listener(old_port)
            masters = self.master_pids(fixture.ssh_ports[0], legacy=False)
            pairs = [pair for pair in fixture.relay.active()
                     if not pair.state()["frozen"] and not pair.state()["frontEOF"] and not pair.state()["backendEOF"]]
            self.check(label + ": current channel and unchanged helper have proven fixture ownership",
                       old_owner is not None and len(masters) == 1 and len(pairs) == 1
                       and before["epoch"] == epoch and await listener(before["port"], helper=True) == fixed_owner)
            pair = pairs[0]
            fixture.ports.add(old_port)
            pair.freeze()
            retained.append({"port": old_port, "owner": old_owner, "pair": pair})
            marker = len(self.events)
            sleep_start = time.monotonic()
            self.record("stage", message=label + ": sleep starts after the active SSH channel becomes a blackhole")
            self.action("sleep")
            await self.wait(lambda: any(item.get("type") == "sleep" for item in self.events[marker:])
                            and not self.master_pids() and not self.gateway_ports(), 12,
                            label + ": blackholed release delayed owned client shutdown beyond twelve seconds")
            closed_seconds = time.monotonic() - sleep_start
            self.check(label + ": owned masters and gateways close within twelve seconds",
                       closed_seconds < 12, {"observed_seconds": round(closed_seconds, 3)})
            await self.wait(lambda: pair.state()["frontEOF"], 5, label + ": retired client EOF was not observed")
            await check_retained(label + ": server listeners survive local sleep cleanup")
            attempts = fixture.relay.count()
            lease_seconds = float(before["lease_seconds"])
            if not 0 < lease_seconds <= 25:
                raise RuntimeError("Unexpected lease duration exceeds the bounded Swift fixture budget")
            hold = lease_seconds + 1.25 if long_sleep else 1.0
            await self.quiet(hold, lambda: not self.master_pids() and not self.gateway_ports()
                             and fixture.relay.count() == attempts and self.phases.get("fixed-a") == "reconnecting",
                             label + ": suspended controller does not reconnect before wake")
            asleep = await self.status(0)
            self.check(label + ": helper and fixed entry persist during sleep",
                       asleep["epoch"] == epoch and asleep["generation"] == before["generation"]
                       and await listener(before["port"], helper=True) == fixed_owner)
            if long_sleep:
                self.check(label + ": the actual active lease expires before wake",
                           asleep["active_generation"] is None and asleep["backend_port"] is None)
            else:
                self.check(label + ": the active lease is still valid before short-sleep wake",
                           asleep["active_generation"] == before["active_generation"] and asleep["backend_port"] == old_port)
            await check_retained(label + ": old ports remain occupied immediately before wake")
            marker = len(self.events)
            wake_start = time.monotonic()
            sleep_seconds = wake_start - sleep_start
            self.action("wake"); self.action("wake")
            await self.wait(lambda: self.phases.get("fixed-a") == "connected" and self.phases.get("legacy") == "connected"
                            and sum(item.get("type") == "wake" for item in self.events[marker:]) == 2,
                            20, label + ": duplicate wake did not promptly restore eligible connections")
            connected_seconds = time.monotonic() - wake_start
            await self.exact_transfer(0)
            data_seconds = time.monotonic() - wake_start
            await self.legacy_transfer()
            after = await self.status(0)
            new_port = after["backend_port"]
            fixture.ports.add(new_port)
            new_owner = await listener(new_port)
            new_masters = self.master_pids(fixture.ssh_ports[0], legacy=False)
            await check_retained(label + ": abandoned ports remain with the same sshd processes after recovery")
            self.check(label + ": wake promptly switches the same fixed entry to a different owned backend",
                       data_seconds < 20 and new_port not in {item["port"] for item in retained}
                       and new_owner is not None and new_owner != old_owner
                       and after["port"] == before["port"] and after["epoch"] == epoch
                       and await listener(before["port"], helper=True) == fixed_owner
                       and after["active_generation"] == after["generation"] > before["generation"]
                       and len(new_masters) == 1 and new_masters != masters)
            await self.quiet(2, lambda: fixture.relay.count() == attempts + 1
                             and len(self.master_pids(fixture.ssh_ports[0], legacy=False)) == 1
                             and len(self.gateway_ports()) == 1 and self.phases.get("fixed-b") == "stopped"
                             and not self.master_pids(fixture.ssh_ports[1], legacy=False),
                             label + ": duplicate wake creates one channel and leaves manual-only B stopped")
            self.check(label + ": wake reports no forwarding conflict or terminal failure",
                       not any(item.get("type") == "status" and item.get("id") == "fixed-a"
                               and (item.get("phase") == "failed" or "端口已占用" in item.get("message", ""))
                               for item in self.events[marker:]))
            self.report["sleepWakeCycles"].append({
                "label": label, "leaseSeconds": lease_seconds, "sleepHoldSeconds": hold,
                "observedSleepSeconds": round(sleep_seconds, 3),
                "ownedClientExitObservedSeconds": round(closed_seconds, 3),
                "wakeToConnectedObservedSeconds": round(connected_seconds, 3),
                "wakeToExactHTTPMarkerObservedSeconds": round(data_seconds, 3),
                "fixedEntryPort": before["port"], "fixedEntryPID": fixed_owner["pid"],
                "oldBackendPort": old_port, "newBackendPort": new_port,
                "oldSSHD": old_owner, "newSSHD": new_owner,
                "oldListenersStillOccupied": True, "helperEpochUnchanged": True,
                "activeLeaseExpiredBeforeWake": asleep["active_generation"] is None,
                "exactHTTPMarkerPassed": True, "manualOnlyBRemainsStopped": True,
            })

        self.action("stop", "fixed-a")
        await self.wait(lambda: self.phases.get("fixed-a") == "stopped"
                        and not self.master_pids(fixture.ssh_ports[0], legacy=False), 10,
                        "Explicit stop after blackhole recovery did not close the owned master")
        released = await self.status(0)
        self.check("normal explicit stop after blackhole recovery releases its active lease", released["backend_port"] is None)
        self.action("start", "fixed-b")
        await self.wait(lambda: self.phases.get("fixed-b") == "connected"
                        and len(self.master_pids(fixture.ssh_ports[1], legacy=False)) == 1
                        and len(self.gateway_ports()) == 1, 20,
                        "Manual-only B did not reconnect before the original lifecycle checks")
        await self.exact_transfer(1)

    async def error_cases(self):
        for identity in ("missing-helper", "wrong-port"):
            before = await self.status(0)
            marker = len(self.events)
            self.action("start", identity)
            await self.wait(lambda: self.phases.get(identity) == "failed", 15, f"{identity} was not a terminal Swift failure")
            after = await self.status(0)
            self.check(f"{identity} fails before helper begin or activation",
                       after["generation"] == before["generation"]
                       and after["active_generation"] == before["active_generation"]
                       and after["backend_port"] == before["backend_port"])
            attempts = self.fixture.relay.count()
            await self.quiet(1, lambda: self.phases.get(identity) == "failed" and self.fixture.relay.count() == attempts,
                             f"{identity} does not retry a permanent configuration error")
            self.check(f"{identity} never publishes a false connected status",
                       not any(item.get("type") == "status" and item.get("id") == identity
                               and item.get("phase") == "connected" for item in self.events[marker:]))
            await self.exact_transfer(0)
        audit = [json.loads(line) for line in (self.fixture.root / "control-audit.jsonl").read_text().splitlines()]
        self.check("missing helper was exercised through a real allowlisted remote SSH invocation",
                   any(item["kind"] == "missing-helper" for item in audit))

    async def lifecycle_cases(self):
        self.action("start", "fixed-a")
        await self.wait(lambda: self.phases.get("fixed-a") == "connected", 20, "Explicit restart of Swift A failed")
        await self.exact_transfer(0)
        marker = len(self.events)
        self.action("sleep"); self.action("sleep")
        await self.wait(lambda: sum(item.get("type") == "sleep" for item in self.events[marker:]) == 2
                        and not self.master_pids() and not self.gateway_ports(), 10, "Swift sleep did not close all owned masters and gateways")
        attempts = self.fixture.relay.count()
        await self.quiet(1, lambda: not self.master_pids() and not self.gateway_ports() and self.fixture.relay.count() == attempts,
                         "sleep suspends fixed and legacy transports without launching replacements")
        marker = len(self.events)
        self.action("wake"); self.action("wake")
        await self.wait(lambda: self.phases.get("fixed-a") == "connected" and self.phases.get("legacy") == "connected"
                        and sum(item.get("type") == "wake" for item in self.events[marker:]) == 2,
                        20, "Swift wake did not resume the previously desired automatic connections")
        await self.exact_transfer(0)
        await self.legacy_transfer()
        await self.quiet(2, lambda: self.fixture.relay.count() == attempts + 1
                         and self.phases.get("fixed-b") == "stopped"
                         and len(self.gateway_ports()) == 1
                         and len(self.master_pids(self.fixture.ssh_ports[1], legacy=False)) == 0,
                         "duplicate wake creates one A transport and does not revive autoReconnect=false B")
        self.check("wake does not revive missing-helper or wrong-port terminal failures",
                   not any(item.get("type") == "status" and item.get("phase") == "connecting"
                           and item.get("id") in {"missing-helper", "wrong-port"} for item in self.events[marker:]))
        marker = len(self.events)
        self.action("sleep")
        await self.wait(lambda: any(item.get("type") == "sleep" for item in self.events[marker:])
                        and not self.master_pids() and not self.gateway_ports(),
                        10, "Second Swift sleep did not close its transports")
        self.action("stop", "fixed-a")
        await self.wait(lambda: self.phases.get("fixed-a") == "stopped", 5, "Stop during Swift sleep was not applied")
        attempts = self.fixture.relay.count()
        self.action("wake")
        await self.wait(lambda: self.phases.get("legacy") == "connected", 15, "Legacy control did not resume")
        await self.quiet(2, lambda: self.phases.get("fixed-a") == "stopped" and self.fixture.relay.count() == attempts,
                         "user stop during sleep cancels native fixed-entry wake intent")
        self.action("start", "fixed-a")
        await self.wait(lambda: self.phases.get("fixed-a") == "connected", 20, "Final Swift explicit start failed")
        entry = await self.status(0)
        self.fixture.ports.add(entry["backend_port"])
        owner = await asyncio.to_thread(fixture_module.listener_owner, entry["backend_port"], self.fixture.sshds[0].pid)
        pairs = [pair for pair in self.fixture.relay.active()
                 if not pair.state()["frozen"] and not pair.state()["frontEOF"] and not pair.state()["backendEOF"]]
        self.check("shutdown regression owns exactly one active channel before blackholing it",
                   owner is not None and len(pairs) == 1)
        pair = pairs[0]
        pair.freeze()
        marker = len(self.events)
        shutdown_start = time.monotonic()
        self.action("sleep")
        # Shutdown must not depend on the release completing over the now-dead channel.
        self.action("shutdown-controller")
        await self.wait(lambda: any(item.get("type") == "sleep" for item in self.events[marker:])
                        and not self.master_pids() and not self.gateway_ports(),
                        10, "Final Swift sleep did not close transports")
        await self.wait(lambda: any(item.get("type") == "shutdown-controller" for item in self.events[marker:]),
                        10, "Swift Controller shutdown did not complete")
        shutdown_seconds = time.monotonic() - shutdown_start
        self.check("shutdown during blackholed sleep release completes within ten seconds",
                   shutdown_seconds < 10, {"observed_seconds": round(shutdown_seconds, 3)})
        retained = await asyncio.to_thread(fixture_module.listener_owner, entry["backend_port"], self.fixture.sshds[0].pid)
        self.check("bounded shutdown preserves the abandoned server-side SSH listener",
                   retained == owner and not pair.state()["backendEOF"])
        self.report["blackholeShutdownObservedSeconds"] = round(shutdown_seconds, 3)
        attempts = self.fixture.relay.count()
        self.action("wake"); self.action("start", "fixed-a")
        await self.quiet(2, lambda: not self.master_pids() and not self.gateway_ports() and self.fixture.relay.count() == attempts,
                         "shutdown while suspended rejects subsequent wake and start")

    async def stop_runner(self):
        if self.runner is None:
            return
        if self.runner.poll() is None:
            self.action("shutdown")
            await asyncio.wait_for(asyncio.to_thread(self.runner.wait), timeout=12)
        self.read_events(strict=False)
        self.check("the real Swift runner shuts down successfully", self.runner.returncode == 0)
        self.check("Swift shutdown removes every private control directory it created",
                   any(item.get("type") == "shutdown" and item.get("directories_removed") is True for item in self.events))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", "--report", dest="report", required=True, type=pathlib.Path)
    parser.add_argument("--binary", type=pathlib.Path, help="Use the actual Swift FixedEntryIntegrationChecks controller runner")
    args = parser.parse_args()
    run = SwiftCheckRun(args.binary.resolve()) if args.binary else CheckRun()
    async def bounded():
        return await asyncio.wait_for(run.run(), timeout=180)
    try:
        report = asyncio.run(bounded())
    except BaseException as error:
        report = run.report
        report["status"] = "failed"
        report["error"] = str(error) or type(error).__name__
    path = args.report.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Fixed-entry real SSH: {report['status']}; report: {path}", flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
