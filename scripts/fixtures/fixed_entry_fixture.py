#!/usr/bin/env python3
"""Private loopback-only SSH resources for the fixed-entry prototype checks."""

import importlib.util
import json
import os
import pathlib
import pwd
import select
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("catunnel_ssh_fixture", pathlib.Path(__file__).with_name("ssh_fixture.py"))
ssh_fixture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ssh_fixture)


def forced_command(root, index):
    manifest = json.loads((root / "fixture.json").read_text())
    original = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    if original == "printf CATUNNEL_FIXTURE_READY":
        sys.stdout.write("CATUNNEL_FIXTURE_READY")
        return 0
    legacy_port = manifest.get("legacyPort")
    if legacy_port is not None and original == ssh_fixture.listener_command(legacy_port):
        result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", f"-iTCP:{legacy_port}",
                                 "-sTCP:LISTEN", "-Fn"], capture_output=True, text=True, timeout=3)
        for line in result.stdout.splitlines():
            if line.startswith("n"):
                print(f"LISTEN 0 0 {line[1:]} 0.0.0.0:*")
        return 0 if result.returncode in (0, 1) else result.returncode
    try:
        arguments = shlex.split(original)
    except ValueError:
        arguments = []
    expected = manifest["control_commands"][index]
    missing = list(expected)
    missing[1] = manifest.get("missingHelperPath")
    if arguments != expected and not (index == 0 and missing[1] is not None and arguments == missing):
        print("Fixture refused an unlisted command", file=sys.stderr)
        return 126
    audit = json.dumps({"index": index, "kind": "control" if arguments == expected else "missing-helper"}) + "\n"
    descriptor = os.open(str(root / "control-audit.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, audit.encode())
    finally:
        os.close(descriptor)
    # The lease ticket and health key remain on the authenticated SSH stdin/stdout.
    # No shell, command echo, public requests, or credential-bearing files are used.
    os.execv(sys.executable, [sys.executable] + arguments[1:])


def process_table():
    result = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,lstart=,comm="],
                            capture_output=True, text=True, check=True, timeout=3)
    table = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 7)
        if len(fields) == 8:
            table[int(fields[0])] = {"parent": int(fields[1]), "birth": " ".join(fields[2:7]), "command": fields[7]}
    return table


def descendants(table, parent):
    found = set()
    while True:
        additional = {pid for pid, value in table.items() if value["parent"] == parent or value["parent"] in found}
        if additional <= found:
            return found
        found |= additional


def listener_owner(port, ancestor=None, exact_pid=None):
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fpcn"],
                            capture_output=True, text=True, timeout=3)
    if result.returncode not in (0, 1):
        raise RuntimeError("lsof failed while checking a fixture listener")
    pids = {int(line[1:]) for line in result.stdout.splitlines() if line.startswith("p")}
    if not pids:
        return None
    if len(pids) != 1:
        raise RuntimeError("A fixture listener has ambiguous ownership")
    pid = next(iter(pids))
    table = process_table()
    process = table.get(pid)
    if process is None:
        return None
    if ancestor is not None:
        name = pathlib.Path(process["command"].split()[0]).name
        if pid not in descendants(table, ancestor) or not name.startswith("sshd"):
            raise RuntimeError("Dynamic listener is not an owned sshd descendant")
    if exact_pid is not None and pid != exact_pid:
        raise RuntimeError("Fixed entry listener does not belong to its fixture helper")
    return {"pid": pid, "birth": process["birth"], "command": process["command"]}


class RelayPair:
    def __init__(self, relay, front, back, number):
        self.relay, self.front, self.back, self.number = relay, front, back, number
        self.lock = threading.RLock()
        self.frozen = self.closed = self.front_eof = self.backend_eof = False
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def state(self):
        with self.lock:
            return {"pair": self.number, "frozen": self.frozen, "closed": self.closed,
                    "frontEOF": self.front_eof, "backendEOF": self.backend_eof}

    def freeze(self):
        with self.lock:
            if self.closed or self.front_eof or self.backend_eof:
                raise RuntimeError("Cannot freeze an inactive fixture relay pair")
            self.frozen = True
            self.relay.record("relay-blackhole", pair=self.number)

    def close(self):
        with self.lock:
            self.closed = True
            self.front.close()
            self.back.close()

    def run(self):
        try:
            while not self.closed:
                with self.lock:
                    sockets = ([] if self.front_eof else [self.front]) + [self.back]
                try:
                    readable, _, _ = select.select(sockets, [], [], 0.15)
                except (OSError, ValueError):
                    break
                for source in readable:
                    with self.lock:
                        try:
                            data = source.recv(65536)
                        except socket.timeout:
                            continue
                        except OSError:
                            data = b""
                        if not data:
                            if source is self.front:
                                self.front_eof = True
                                self.relay.record("relay-front-eof", pair=self.number)
                                # Retain the old server transport after the owned client exits.
                                if self.frozen:
                                    self.front.close()
                                    continue
                            else:
                                self.backend_eof = True
                                self.relay.record("relay-backend-eof", pair=self.number)
                            self.closed = True
                            break
                        if not self.frozen:
                            (self.back if source is self.front else self.front).sendall(data)
        except OSError as error:
            self.relay.record("relay-io-error", pair=self.number, error=str(error))
        finally:
            self.close()


class ByteDroppingRelay:
    def __init__(self, listener, backend_port, record):
        self.listener, self.backend_port, self.record = listener, backend_port, record
        self.port = listener.getsockname()[1]
        self.pairs, self.errors, self.lock = [], [], threading.RLock()
        self.stopping = threading.Event()
        listener.settimeout(0.15)
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stopping.is_set():
            front = back = None
            try:
                front, _ = self.listener.accept()
                back = socket.create_connection(("127.0.0.1", self.backend_port), timeout=2)
                front.settimeout(2)
                back.settimeout(2)
                with self.lock:
                    pair = RelayPair(self, front, back, len(self.pairs) + 1)
                    self.pairs.append(pair)
                    self.record("relay-accepted", pair=pair.number)
            except socket.timeout:
                if front is not None:
                    front.close()
                if back is not None:
                    back.close()
            except OSError as error:
                if front is not None:
                    front.close()
                if back is not None:
                    back.close()
                if not self.stopping.is_set():
                    self.errors.append(str(error))

    def active(self):
        with self.lock:
            return [pair for pair in self.pairs if not pair.state()["closed"]]

    def count(self):
        with self.lock:
            return len(self.pairs)

    def close(self):
        self.stopping.set()
        self.listener.close()
        self.thread.join(timeout=3)
        with self.lock:
            pairs = list(self.pairs)
        for pair in pairs:
            pair.close()
        for pair in pairs:
            pair.thread.join(timeout=3)
        if self.thread.is_alive() or any(pair.thread.is_alive() for pair in pairs):
            raise RuntimeError("A fixture relay thread survived cleanup")


class SSHFixture:
    def __init__(self, root, helper_path, record):
        self.root, self.helper_path, self.record = root, helper_path, record
        self.processes, self.sshds, self.helpers, self.logs, self.servers, self.reservations = [], [], [], [], [], []
        self.ports, self.owned, self.control_directories = set(), {}, set()
        self.relay = None
        self.trust_digest = None
        self.user = pwd.getpwuid(os.getuid()).pw_name

    def capture_owned(self):
        table = process_table()
        for pid in descendants(table, os.getpid()):
            self.owned[pid] = table[pid]["birth"]

    def setup(self, markers, include_swift=False):
        root = self.root
        for name in ("host_a", "host_b", "client"):
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5)
        (root / "authorized_keys").write_bytes((root / "client.pub").read_bytes())
        (root / "authorized_keys").chmod(0o600)
        for marker in markers:
            server = ssh_fixture.http_fixture(marker)
            self.servers.append(server)
            self.ports.add(server.server_port)
        self.runtimes = [root / "entry-a", root / "entry-b"]
        self.entry_ready = []
        for index, runtime in enumerate(self.runtimes):
            runtime.mkdir(mode=0o700)
            process = self.spawn([sys.executable, str(self.helper_path), "serve", "--runtime-dir", str(runtime),
                                  "--port", "0", "--lease-seconds", "20"], f"entry-{index}.log")
            self.helpers.append(process)
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Fixture fixed-entry helper exited before becoming ready")
                ready_path = runtime / "ready.json"
                if ready_path.exists():
                    try:
                        ready = json.loads(ready_path.read_text())
                    except (json.JSONDecodeError, FileNotFoundError):
                        time.sleep(0.05)
                        continue
                    if ready["pid"] != process.pid or not 1024 <= ready["port"] <= 65535:
                        raise RuntimeError("Fixture helper published an unexpected PID or port")
                    self.entry_ready.append(ready)
                    self.ports.add(ready["port"])
                    break
                time.sleep(0.05)
            else:
                raise TimeoutError("Fixture fixed-entry helper readiness timed out")
        self.reservations = [ssh_fixture.reserved_socket() for _ in range(4 if include_swift else 3)]
        backend_ports = [item.getsockname()[1] for item in self.reservations[:2]]
        self.ports.update(backend_ports)
        self.relay = ByteDroppingRelay(self.reservations[2], backend_ports[0], self.record)
        self.ssh_ports = [self.relay.port, backend_ports[1]]
        self.ports.update(self.ssh_ports)
        commands = [["python3", str(self.helper_path), "control", "--runtime-dir", str(runtime)] for runtime in self.runtimes]
        manifest = {"control_commands": commands}
        if include_swift:
            self.legacy_port = self.reservations[3].getsockname()[1]
            self.ports.add(self.legacy_port)
            manifest.update(root=str(root), user=self.user, sshPorts=self.ssh_ports,
                            localPorts=[server.server_port for server in self.servers],
                            entryPorts=[item["port"] for item in self.entry_ready], legacyPort=self.legacy_port,
                            helperPath=str(self.helper_path), missingHelperPath=str(root / "missing-helper.py"),
                            runtimePaths=[str(path) for path in self.runtimes], markers=markers)
        (root / "fixture.json").write_text(json.dumps(manifest))
        known_hosts = []
        for port, host in zip(self.ssh_ports, ("host_a", "host_b")):
            fields = (root / (host + ".pub")).read_text().split()
            known_hosts.append(f"[127.0.0.1]:{port} {fields[0]} {fields[1]}\n")
        (root / "known_hosts").write_text("".join(known_hosts))
        (root / "known_hosts").chmod(0o600)
        self.trust_digest = ssh_fixture.digest(root / "known_hosts")
        for index, host in enumerate(("host_a", "host_b")):
            force = shlex.join([sys.executable, str(pathlib.Path(__file__).resolve()), "--forced-command", str(root), str(index)])
            config = "\n".join([
                f"Port {backend_ports[index]}", "ListenAddress 127.0.0.1", f"HostKey {root}/{host}",
                f"PidFile {root}/sshd-{index}.pid", f"AuthorizedKeysFile {root}/authorized_keys",
                f"AllowUsers {self.user}", "AuthenticationMethods publickey", "PubkeyAuthentication yes",
                "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no", "UseDNS no",
                "StrictModes yes", "AllowTcpForwarding remote", "GatewayPorts no", "AllowAgentForwarding no",
                "X11Forwarding no", "PermitTunnel no", "PermitUserEnvironment no", "PrintMotd no",
                "MaxAuthTries 2", "LogLevel ERROR", "ClientAliveInterval 0", "ForceCommand " + force, "",
            ])
            config_path = root / f"sshd-{index}.conf"
            config_path.write_text(config)
            subprocess.run(["/usr/sbin/sshd", "-t", "-f", str(config_path)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=5)
            self.reservations[index].close()
            self.sshds.append(self.spawn(["/usr/sbin/sshd", "-D", "-e", "-f", str(config_path)], f"sshd-{index}.log"))
        for port in self.ssh_ports:
            for attempt in range(12):
                result = subprocess.run(ssh_fixture.ssh_arguments(root, port, self.user),
                                        capture_output=True, text=True, timeout=5)
                if result.returncode == 0 and result.stdout == "CATUNNEL_FIXTURE_READY":
                    break
                if attempt == 11:
                    raise RuntimeError("Disposable strict-key SSH readiness failed: " + result.stderr[-1000:])
                time.sleep(0.1)
        self.relay.errors.clear()
        if include_swift:
            self.reservations[3].close()
        self.capture_owned()

    def spawn(self, arguments, log_name):
        log = (self.root / log_name).open("wb")
        self.logs.append(log)
        process = subprocess.Popen(arguments, stdout=log, stderr=log, start_new_session=True)
        self.processes.append(process)
        self.capture_owned()
        return process

    def remember_client(self, client):
        for port in (client.backend_port, client.gateway_port):
            if port is not None:
                self.ports.add(port)
        directory = client.control_directory
        if directory is not None:
            self.control_directories.add(pathlib.Path(directory))
        self.capture_owned()

    def fault_owned_master(self, pid):
        table = process_table()
        process = table.get(pid)
        if process is None or pid not in descendants(table, os.getpid()) or pathlib.Path(process["command"]).name != "ssh":
            raise RuntimeError("Refusing to fault a process without owned SSH ancestry")
        command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                                 capture_output=True, text=True, check=True, timeout=3).stdout
        if "UserKnownHostsFile=" + str(self.root / "known_hosts") not in command:
            raise RuntimeError("Refusing to fault an SSH process outside the private fixture trust store")
        self.owned[pid] = process["birth"]
        if process_table().get(pid, {}).get("birth") != process["birth"]:
            raise RuntimeError("Owned SSH identity changed before fault injection")
        os.kill(pid, signal.SIGTERM)
        self.record("fault-owned-client-master", pid=pid)

    def cleanup(self):
        errors = []
        def attempt(function):
            try:
                return function()
            except Exception as error:
                errors.append(str(error))
                return None
        attempt(self.capture_owned)
        if self.relay is not None:
            attempt(self.relay.close)
        for process in reversed(self.processes):
            def stop(process=process):
                current = process_table().get(process.pid)
                if current is not None and current["birth"] == self.owned.get(process.pid):
                    ssh_fixture.stop_owned_process(process)
            attempt(stop)
        for sig in (signal.SIGTERM, signal.SIGKILL):
            table = attempt(process_table) or {}
            for pid, birth in self.owned.items():
                if table.get(pid, {}).get("birth") == birth:
                    def send(pid=pid, sig=sig):
                        try:
                            os.kill(pid, sig)
                        except ProcessLookupError:
                            pass
                    attempt(send)
            time.sleep(0.2)
        for process in self.processes:
            attempt(lambda process=process: process.wait(timeout=2))
        for reservation in self.reservations:
            attempt(reservation.close)
        for server in self.servers:
            attempt(server.shutdown)
            attempt(server.server_close)
        for log in self.logs:
            attempt(log.close)
        end = time.monotonic() + 4
        ports_closed = clients_closed = False
        while time.monotonic() < end:
            ports_closed = attempt(lambda: ssh_fixture.ports_closed(self.ports))
            clients_closed = attempt(lambda: not ssh_fixture.fixture_ssh_clients(self.root))
            if ports_closed and clients_closed:
                break
            time.sleep(0.1)
        table = attempt(process_table) or {}
        remaining = [pid for pid, birth in self.owned.items() if table.get(pid, {}).get("birth") == birth]
        trust_unchanged = self.trust_digest is None or (
            (self.root / "known_hosts").exists() and ssh_fixture.digest(self.root / "known_hosts") == self.trust_digest)
        return {"errors": errors, "allFixturePortsClosed": bool(ports_closed), "noFixtureSSHClients": bool(clients_closed),
                "noOwnedProcessesRemain": not remaining, "privateTrustUnchanged": trust_unchanged,
                "clientControlDirectoriesRemoved": all(not path.exists() for path in self.control_directories)}


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--forced-command" and sys.argv[3] in ("0", "1"):
        raise SystemExit(forced_command(pathlib.Path(sys.argv[2]), int(sys.argv[3])))
    raise SystemExit("This module is only a disposable fixture; use scripts/check-fixed-entry.py")
