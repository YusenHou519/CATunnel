#!/usr/bin/env python3
"""Exercise the real Swift installer against disposable SSH servers and a private HOME."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
REPOSITORY = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("install_ssh_fixture", Path(__file__).parent / "fixtures/fixed_entry_fixture.py")
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)


def audit(root, **record):
    descriptor = os.open(str(root / "install-audit.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, (json.dumps(record) + "\n").encode())
    finally:
        os.close(descriptor)


def forced_command(root, index):
    manifest = json.loads((root / "fixture.json").read_text())
    try:
        arguments = shlex.split(os.environ.get("SSH_ORIGINAL_COMMAND", ""))
    except ValueError:
        return 126
    script = Path(manifest["installerScriptPath"]).read_text()
    digest = hashlib.sha256(Path(manifest["helperPath"]).read_bytes()).hexdigest()
    ports = manifest["installPorts"] + [manifest["localPorts"][1]]
    interpreters = ["python3", manifest["selectedPythonPath"], manifest["missingPythonPath"]]
    interpreter = arguments[0] if arguments else ""
    for port in ports:
        expected = [interpreter, "-c", script, "--port", str(port), "--sha256", digest]
        if interpreter in interpreters and arguments == expected:
            if interpreter == "python3" and (root / "missing-python").exists():
                audit(root, kind="missing-python", port=port, interpreter=interpreter, injected=True)
                sys.stderr.write("python3: command not found\n")
                return 127
            if interpreter == "python3" and (root / "old-default-python").exists():
                audit(root, kind="install", port=port, interpreter=interpreter, injected=True,
                      ok=False, error="python_unsupported")
                print(json.dumps(dict(version=1, ok=False, error="python_unsupported")))
                return 1
            environment = dict(os.environ, HOME=manifest["fixtureHome"], PYTHONDONTWRITEBYTECODE="1")
            executable = sys.executable if interpreter == "python3" else interpreter
            try:
                result = subprocess.run([executable] + arguments[1:], stdin=sys.stdin.buffer,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=30)
            except FileNotFoundError:
                audit(root, kind="missing-selected-python", port=port, interpreter=interpreter, injected=False)
                sys.stderr.write(f"{interpreter}: command not found\n")
                return 127
            try:
                response = json.loads(result.stdout)
            except ValueError:
                response = {}
            audit(root, kind="install", port=port, ok=response.get("ok"), error=response.get("error"),
                  reused=response.get("reused"), interpreter=interpreter, injected=False)
            delay = root / f"delay-install-{port}"
            if response.get("ok") is True and delay.exists():
                (root / f"installed-before-reply-{port}").touch(exist_ok=False)
                deadline = time.monotonic() + 10
                while delay.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
            sys.stdout.buffer.write(result.stdout)
            return result.returncode
        helper = Path(manifest["fixtureHome"]) / ".catunnel/fixed-entry" / str(port) / "relay.py"
        runtime = helper.parent / "r"
        expected_control = [interpreter, str(helper), "control", "--runtime-dir", str(runtime)]
        if interpreter in interpreters and arguments == expected_control:
            request = sys.stdin.buffer.readline(4097)
            try:
                operation = json.loads(request).get("op")
            except (ValueError, AttributeError):
                return 126
            if len(request) > 4096 or operation not in ("status", "begin", "activate", "renew", "release"):
                return 126
            if interpreter == "python3" and (root / "old-default-python").exists():
                audit(root, kind="installed-control", port=port, interpreter=interpreter, op=operation,
                      injected=True, ok=False, error="python_unsupported")
                return 1
            executable = sys.executable if interpreter == "python3" else interpreter
            environment = dict(os.environ, HOME=manifest["fixtureHome"], PYTHONDONTWRITEBYTECODE="1")
            try:
                result = subprocess.run([executable] + arguments[1:], input=request, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=environment, timeout=10)
            except FileNotFoundError:
                audit(root, kind="missing-selected-python", port=port, interpreter=interpreter,
                      op=operation, injected=False)
                return 127
            try:
                response = json.loads(result.stdout)
            except ValueError:
                response = {}
            # Only operation names and success flags are recorded; lease tickets and keys stay private.
            audit(root, kind="installed-control", port=port, interpreter=interpreter, op=operation,
                  ok=response.get("ok"), exitCode=result.returncode, injected=False)
            sys.stdout.buffer.write(result.stdout)
            return result.returncode
    return fixture_module.forced_command(root, index)


class InstallFixture(fixture_module.SSHFixture):
    def __init__(self, root, home, record):
        super().__init__(root, REPOSITORY / "experimental/fixed_entry/relay.py", record)
        self.install_home = home
        self.python_directory = home / "bin"
        self.python_directory.mkdir(mode=0o700)
        self.selected_python = self.python_directory / "python 'selected 3"
        self.selected_python.symlink_to(sys.executable)
        self.missing_python = self.python_directory / "python missing"
        self.runtime_executables = {sys.executable, str(Path(sys.executable).resolve()), str(self.selected_python)}
        self.install_reservations = [fixture_module.ssh_fixture.reserved_socket() for _ in range(5)]
        self.install_ports = [item.getsockname()[1] for item in self.install_reservations]
        self.ports.update(self.install_ports)
        (root / "unknown_hosts").write_bytes(b"")
        (root / "unknown_hosts").chmod(0o600)

    def spawn(self, arguments, log_name):
        if arguments[0] == "/usr/sbin/sshd":
            path = self.root / "fixture.json"
            manifest = json.loads(path.read_text())
            manifest.update(installPorts=self.install_ports, installerScriptPath=str(REPOSITORY / "experimental/fixed_entry/install.py"),
                            helperPath=str(self.helper_path), fixtureHome=str(self.install_home),
                            selectedPythonPath=str(self.selected_python), missingPythonPath=str(self.missing_python))
            path.write_text(json.dumps(manifest))
            index = len(self.sshds)
            config = Path(arguments[-1])
            force = shlex.join([sys.executable, str(Path(__file__).resolve()), "--forced-command", str(self.root), str(index)])
            config.write_text("\n".join("ForceCommand " + force if line.startswith("ForceCommand ") else line
                                        for line in config.read_text().splitlines()) + "\n")
        return super().spawn(arguments, log_name)

    def capture_owned(self):
        super().capture_owned()
        # Detached helpers have already lost their SSH parent. Identify only processes
        # executing the exact private fixture script and runtime, then retain birth identity.
        table = fixture_module.process_table()
        # Apple's Python launcher execs a framework binary. Learn that exact executable
        # only from still-running helper children created by this fixture's own Popen.
        for process in self.helpers:
            current = table.get(process.pid)
            if process.poll() is None and current is not None and self.owned.get(process.pid) == current["birth"]:
                executable = current["command"]
                if Path(executable).is_absolute():
                    self.runtime_executables.add(executable)
        result = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True, timeout=3)
        for line in result.stdout.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) != 2 or not fields[0].isdigit():
                continue
            pid = int(fields[0])
            for port in self.install_ports:
                base = self.install_home / ".catunnel/fixed-entry" / str(port)
                expected = [str(base / "relay.py"), "serve", "--runtime-dir", str(base / "r"), "--port", str(port)]
                # ps does not quote executable paths. Match the exact known prefix before
                # splitting arguments so the deliberately quoted Python path remains identifiable.
                matching = [executable for executable in self.runtime_executables if fields[1].startswith(executable + " ")]
                tails = [fields[1][len(executable) + 1:] for executable in matching]
                matched = any(tail == " ".join(expected) or tail == "-I " + " ".join(expected) for tail in tails)
                if matched and pid in table:
                    self.owned[pid] = table[pid]["birth"]

    def cleanup(self):
        for item in self.install_reservations:
            item.close()
        return super().cleanup()


def run(binary, output):
    report = {"suite": "fixed-entry-install-real-ssh", "status": "failed", "checks": [],
              "limits": ["Temporary macOS SSH servers and private fixture HOME only; no real server deployment.",
                         "Old default Python is a labelled injected failure; selected Python executes the real local interpreter through a private symlink.",
                         "No Linux, physical sleep, system service, or public egress validation."]}
    started = time.monotonic()
    root = home = None
    try:
        base = Path(os.environ["TMPDIR"]).resolve()
        info = base.stat()
        if info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise RuntimeError("SSH fixture requires the current user's private TMPDIR")
        # Keep SSH authentication files under the private TMPDIR for StrictModes.
        # The separate private HOME is short enough for the helper's Unix socket.
        with tempfile.TemporaryDirectory(prefix="cati.", dir=base) as temporary, \
                tempfile.TemporaryDirectory(prefix="caih.", dir="/private/tmp") as temporary_home:
            root = Path(temporary).resolve()
            home = Path(temporary_home).resolve()
            root.chmod(0o700)
            home.chmod(0o700)
            fixture = InstallFixture(root, home, lambda kind, **fields: None)
            try:
                markers = ["catunnel-install-fixture-a", "catunnel-install-fixture-b"]
                fixture.setup(markers, include_swift=True)
                for item in fixture.install_reservations:
                    item.close()
                process = fixture.spawn([str(binary), str(root / "fixture.json")], "install-swift.log")
                deadline = time.monotonic() + 150
                while process.poll() is None and time.monotonic() < deadline:
                    fixture.capture_owned()
                    time.sleep(0.1)
                if process.poll() is None:
                    raise TimeoutError("Swift installation checks exceeded 150 seconds")
                saved = root / "install-result.json"
                if saved.exists():
                    result = json.loads(saved.read_text())
                    report["checks"] = result["checks"]
                    report["swiftError"] = result.get("error")
                if process.returncode != 0:
                    raise RuntimeError("Swift installation checks failed")
                report["status"] = "passed"
            finally:
                report["cleanup"] = fixture.cleanup()
                report["runtimePythonExecutables"] = sorted(fixture.runtime_executables)
                report["serviceLogs"] = {path.name: path.read_text(errors="replace")[-4000:].replace(str(root), "<fixture>")
                                         for path in root.glob("*.log")}
                audit_path = root / "install-audit.jsonl"
                report["audit"] = [json.loads(line) for line in audit_path.read_text().splitlines()] if audit_path.exists() else []
                for name, value in report["cleanup"].items():
                    if name != "errors":
                        report["checks"].append({"name": name, "passed": bool(value)})
                if report["cleanup"]["errors"] or any(not item["passed"] for item in report["checks"]):
                    report["status"] = "failed"
    except Exception as error:
        report["error"] = str(error)
        report["status"] = "failed"
    report["temporaryFixtureRemoved"] = (root is None or not root.exists()) and (home is None or not home.exists())
    if not report["temporaryFixtureRemoved"]:
        report["status"] = "failed"
    report["durationSeconds"] = round(time.monotonic() - started, 3)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Fixed-entry installation SSH: {report['status']}; report: {output}")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--forced-command" and sys.argv[3] in ("0", "1"):
        raise SystemExit(forced_command(Path(sys.argv[2]), int(sys.argv[3])))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    raise SystemExit(run(arguments.binary.resolve(), arguments.output.resolve()))
