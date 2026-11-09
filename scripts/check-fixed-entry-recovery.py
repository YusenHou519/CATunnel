#!/usr/bin/env python3
"""Real Swift-controller recovery checks using disposable loopback SSH fixtures.

Run after building FixedEntryIntegrationChecks:
  python3 scripts/check-fixed-entry-recovery.py --binary .build/debug/FixedEntryIntegrationChecks --output REPORT
No personal SSH configuration, installed app, production server or public API is used.
"""

import argparse
import asyncio
import http.server
import importlib.util
import json
import pathlib
import sys
import threading
import time

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("fixed_entry_regression", pathlib.Path(__file__).with_name("check-fixed-entry.py"))
regression = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(regression)


class RecoveryCheckRun(regression.SwiftCheckRun):
    def __init__(self, binary):
        super().__init__(binary)
        self.report["suite"] = "fixed-entry-swift-control-timeout-recovery"
        self.report["limits"] = [
            "Actual Swift controller and real private loopback SSH; no production resources or public APIs.",
            "One fixture control wrapper delays a successful renewal reply beyond six seconds; it never logs request bodies.",
            "A separate byte relay blackholes only fixture A; TCP ACKs remain active while SSH bytes are discarded.",
            "The long response is silent for 75 wall-clock seconds; no clock or production timeout is shortened.",
        ]
        self.held_writer = None
        self.long_task = None
        self.release_hold = threading.Event()
        self.long_seen = threading.Event()
        self.hold_seen = threading.Event()

    def install_control_fault(self):
        root = self.fixture.root
        wrapper = root / "control-fault.py"
        source = r'''import json,os,pathlib,subprocess,sys,time
sys.dont_write_bytecode=True
root=pathlib.Path(ROOT)
request=sys.stdin.buffer.readline(4097)
try:
    operation=json.loads(request).get("op")
    runtime=pathlib.Path(sys.argv[sys.argv.index("--runtime-dir")+1])
except Exception:
    raise SystemExit(2)
result=subprocess.run([sys.executable,HELPER,"control","--runtime-dir",str(runtime)],input=request,capture_output=True)
try:ok=json.loads(result.stdout).get("ok") is True
except Exception:ok=False
if operation=="renew" and runtime==root/"entry-a" and ok:
    try:
        fd=os.open(str(root/"renew-fault-used"),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
        os.close(fd)
        delayed=True
    except FileExistsError:
        delayed=False
    event={"kind":"renew_reply_delayed" if delayed else "renew_ok","at_unix":time.time()}
    fd=os.open(str(root/"renew-observations.jsonl"),os.O_CREAT|os.O_APPEND|os.O_WRONLY,0o600)
    try:os.write(fd,(json.dumps(event)+"\n").encode())
    finally:os.close(fd)
    if delayed:time.sleep(12)
sys.stdout.buffer.write(result.stdout)
sys.stdout.buffer.flush()
sys.stderr.buffer.write(result.stderr)
raise SystemExit(result.returncode)
'''.replace("ROOT", repr(str(root))).replace("HELPER", repr(str(self.fixture.helper_path)))
        wrapper.write_text(source)
        wrapper.chmod(0o700)
        manifest_path = root / "fixture.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["helperPath"] = str(wrapper)
        manifest["control_commands"] = [["python3", str(wrapper), "control", "--runtime-dir", str(runtime)]
                                        for runtime in self.fixture.runtimes]
        manifest_path.write_text(json.dumps(manifest))

    def install_delayed_origin(self):
        marker = self.markers[0].encode()
        long_seen, hold_seen, release_hold = self.long_seen, self.hold_seen, self.release_hold

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/delayed75":
                    long_seen.set()
                    time.sleep(75)
                elif self.path == "/held-response":
                    hold_seen.set()
                    release_hold.wait(60)
                try:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(marker)))
                    self.end_headers()
                    self.wfile.write(marker)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *_args):
                pass

        self.fixture.servers[0].RequestHandlerClass = Handler

    def renewal_observations(self):
        path = self.fixture.root / "renew-observations.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.endswith("}")]

    def timeout_events(self, offset):
        result = []
        for event in self.events[offset:]:
            message = str(event.get("message", "")).lower()
            if event.get("type") == "log" and event.get("id") == "fixed-a" and "renew" in message:
                if any(marker in message for marker in ("超时=true", "timedout=true", "timed out", "timeout=true")):
                    result.append(event)
        return result

    async def delayed_transfer(self):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.fixture.entry_ready[0]["port"])
        started = time.monotonic()
        try:
            writer.write(b"GET /delayed75 HTTP/1.0\r\nHost: fixture.example\r\n\r\n")
            await writer.drain()
            data = await asyncio.wait_for(reader.read(65536), timeout=90)
            while not reader.at_eof():
                next_bytes = await asyncio.wait_for(reader.read(65536), timeout=5)
                if not next_bytes:
                    break
                data += next_bytes
            body = data.partition(b"\r\n\r\n")[2]
            elapsed = time.monotonic() - started
            self.check("actual Swift fixed-entry stream delivers a response after 75 silent seconds",
                       data.startswith(b"HTTP/1.0 200") and body == self.markers[0].encode() and 74 <= elapsed < 88,
                       {"elapsed_seconds": round(elapsed, 3)})
            self.report["silentResponseSeconds"] = round(elapsed, 3)
        finally:
            writer.close()
            await writer.wait_closed()

    async def exercise(self, _client_class):
        fixture = self.fixture
        self.install_control_fault()
        self.install_delayed_origin()
        self.runner = fixture.spawn([str(self.binary), str(fixture.root / "fixture.json")], "swift-runner.log")
        await self.wait(lambda: all(self.phases.get(identity) == "connected" for identity in ("fixed-a", "fixed-b", "legacy")),
                        35, "Actual Swift controller did not connect the isolated profiles")
        for index in range(2):
            await self.exact_transfer(index)
        self.health_task = asyncio.create_task(self.health_monitor())
        before = [await self.status(index) for index in range(2)]
        masters = [self.master_pids(fixture.ssh_ports[index], legacy=False) for index in range(2)]
        self.check("both fixed profiles own exactly one private SSH master", all(len(items) == 1 for items in masters))
        marker = len(self.events)
        self.long_task = asyncio.create_task(self.delayed_transfer())
        await self.wait(self.long_seen.is_set, 5, "Long request did not reach its private origin")
        await self.wait(lambda: any(item["kind"] == "renew_reply_delayed" for item in self.renewal_observations()),
                        15, "One-time successful renewal reply was not delayed")
        delayed_at = next(item["at_unix"] for item in self.renewal_observations() if item["kind"] == "renew_reply_delayed")
        await self.wait(lambda: bool(self.timeout_events(marker)), 10,
                        "The real controller did not report its six-second renew timeout")
        await self.wait(lambda: any(item["kind"] == "renew_ok" and item["at_unix"] > delayed_at for item in self.renewal_observations()),
                        10, "Controller did not successfully renew again after the delayed reply")
        after = await self.status(0)
        self.check("lost renewal reply recovers without changing master, backend or generation",
                   self.master_pids(fixture.ssh_ports[0], legacy=False) == masters[0]
                   and after["backend_port"] == before[0]["backend_port"]
                   and after["active_generation"] == before[0]["active_generation"]
                   and not self.long_task.done())
        recovered_at = min(item["at_unix"] for item in self.renewal_observations()
                           if item["kind"] == "renew_ok" and item["at_unix"] > delayed_at)
        self.report["lostReplyRecoverySeconds"] = round(recovered_at - delayed_at, 3)
        await self.wait(self.long_task.done, 85, "Long-response task did not finish")
        await self.long_task
        self.long_task = None

        reader, self.held_writer = await asyncio.open_connection("127.0.0.1", before[0]["port"])
        self.held_writer.write(b"GET /held-response HTTP/1.0\r\nHost: fixture.example\r\n\r\n")
        await self.held_writer.drain()
        await self.wait(self.hold_seen.is_set, 5, "Held stream did not reach the origin before blackhole")
        pairs = [pair for pair in fixture.relay.active()
                 if not pair.state()["frozen"] and not pair.state()["frontEOF"] and not pair.state()["backendEOF"]]
        self.check("permanent fault targets only one fixture-A SSH transport", len(pairs) == 1)
        renewals = [item["at_unix"] for item in self.renewal_observations() if item["kind"] == "renew_ok"]
        last_confirmed = max(renewals)
        started = time.monotonic()
        started_unix = time.time()
        marker = len(self.events)
        pairs[0].freeze()
        eof = await asyncio.wait_for(reader.read(1), timeout=22)
        stream_closed = time.monotonic() - started
        safe_upper_bound = max(0, last_confirmed + before[0]["lease_seconds"] - started_unix) + 1.5
        self.check("permanent blackhole closes the existing stream by the confirmed lease deadline",
                   eof == b"" and stream_closed <= safe_upper_bound,
                   {"observed_seconds": round(stream_closed, 3), "upper_bound_seconds": round(safe_upper_bound, 3)})
        self.release_hold.set()
        self.held_writer.close()
        await self.held_writer.wait_closed()
        self.held_writer = None
        await self.wait(lambda: masters[0][0] not in self.master_pids(fixture.ssh_ports[0], legacy=False),
                        4, "Timed-out old master survived the lease deadline")
        def recovered_connected():
            current = self.master_pids(fixture.ssh_ports[0], legacy=False)
            return self.phases.get("fixed-a") == "connected" and len(current) == 1 and masters[0][0] not in current

        await self.wait(recovered_connected,
                        15, "Actual Swift controller did not recover after permanent blackhole")
        recovered = await self.status(0)
        self.check("permanent blackhole recovery gets a new backend and newer generation",
                   type(recovered["backend_port"]) is int and type(recovered["active_generation"]) is int
                   and recovered["backend_port"] != before[0]["backend_port"]
                   and recovered["active_generation"] > before[0]["active_generation"])
        fixture.ports.update([before[0]["backend_port"], recovered["backend_port"]])
        await self.exact_transfer(0)
        healthy = await self.status(1)
        self.check("independent profile keeps its master, backend and generation through both faults",
                   self.master_pids(fixture.ssh_ports[1], legacy=False) == masters[1]
                   and healthy["backend_port"] == before[1]["backend_port"]
                   and healthy["active_generation"] == before[1]["active_generation"])
        await self.exact_transfer(1)
        self.report["blackholeStreamClosedSeconds"] = round(stream_closed, 3)
        self.report["status"] = "passed"

    async def stop_runner(self):
        self.release_hold.set()
        if self.long_task is not None:
            self.long_task.cancel()
            await asyncio.gather(self.long_task, return_exceptions=True)
            self.long_task = None
        if self.held_writer is not None:
            self.held_writer.close()
            await self.held_writer.wait_closed()
            self.held_writer = None
        await super().stop_runner()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    run = RecoveryCheckRun(args.binary.resolve())
    try:
        report = asyncio.run(asyncio.wait_for(run.run(), timeout=180))
    except BaseException as error:
        report = run.report
        report["status"] = "failed"
        report["error"] = str(error) or type(error).__name__
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Swift fixed-entry recovery: {report['status']}; report: {output}", flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
