#!/usr/bin/env python3
"""Disposable macOS OpenSSH fixture; all TCP endpoints bind 127.0.0.1.

Listener verification uses real lsof results. Public website/IP-risk responses
are injected through an sshd ForceCommand allowlist, never requested online.
This does not validate a Linux ss installation, Clash, or public API access.
"""

import argparse
import hashlib
import http.server
import json
import os
import pathlib
import platform
import pwd
import secrets
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time


def listener_command(port):
    return (f"/usr/sbin/lsof -nP -a -iTCP:{port} -sTCP:LISTEN -Fn | "
            "/usr/bin/awk '/^n/ {print \"LISTEN 0 0 \" substr($0, 2) \" 0.0.0.0:*\"}'")


def record_diagnostic(root, category, url, proxy_port):
    with (root / "diagnostic-audit.jsonl").open("a") as audit:
        audit.write(json.dumps({"category": category, "url": url, "proxy_port": proxy_port,
                                "executed_public_request": False}) + "\n")


def ping0_fixture_html():
    # Minimal controlled response, not a copy of the public page or executable script.
    return """<!doctype html><html><head><title>192.0.2.1-IP查询</title></head><body>
<div class="info asninfo"><div class="content">
<div class="line ip"><div class="content"><a href="https://ping0.cc/trace/192.0.2.1">trace</a></div></div>
<div class="line line-iptype"><div class="content"><span class="label orange">家庭宽带 IP</span></div></div>
<div class="line line-risk"><div class="content"><div class="riskbar"><div class="riskitem riskcurrent">
<span class="value">23%</span><span class="lab">低风险</span></div></div></div></div>
<div class="line line-usecount"><div class="content"><div class="usecountbar" usecount="1 - 10 (极好)">1 - 10 (极好)</div></div></div>
</div></div></body></html>"""


def force_command(root):
    """The fixture SSH server cannot execute arbitrary remote commands."""
    fixture = json.loads((root / "fixture.json").read_text())
    original = os.environ.get("SSH_ORIGINAL_COMMAND", "")
    if original == "printf CATUNNEL_FIXTURE_READY":
        sys.stdout.write("CATUNNEL_FIXTURE_READY")
        return 0
    if original == "printf '%s' \"$SSH_CONNECTION\"":
        sys.stdout.write(os.environ.get("SSH_CONNECTION", ""))
        return 0
    for port in fixture["remotePorts"] + [fixture["occupiedPort"]]:
        if original == listener_command(port):
            if (root / f"listener-unavailable-{port}").exists():
                print("Fixture: ss: command not found", file=sys.stderr)
                return 127
            delay_once = root / f"listener-delay-once-{port}"
            try:
                delay_once.unlink()
            except FileNotFoundError:
                pass
            else:
                # Consume before waiting so only one query crosses the real 5s timeout.
                time.sleep(6)
            result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", f"-iTCP:{port}",
                                     "-sTCP:LISTEN", "-Fn"], capture_output=True, text=True, check=False)
            for line in result.stdout.splitlines():
                if line.startswith("n"):
                    print(f"LISTEN 0 0 {line[1:]} 0.0.0.0:*")
            return 0 if result.returncode in (0, 1) else result.returncode
    if original.startswith("curl -q "):
        arguments = shlex.split(original)
        url = arguments[-1]
        try:
            proxy = arguments[arguments.index("--proxy") + 1]
        except (ValueError, IndexError):
            print("Fixture refused a diagnostic without its loopback proxy", file=sys.stderr)
            return 126
        proxy_port = next((port for port in fixture["remotePorts"]
                           if proxy == f"http://127.0.0.1:{port}"), None)
        if proxy_port is None:
            print("Fixture refused a diagnostic outside its allocated ports", file=sys.stderr)
            return 126
        website_targets = {
            "https://api.openai.com/v1/models": "openAI",
            "https://api.anthropic.com/v1/models": "claudeAPI",
            "https://www.google.com/generate_204": "google",
        }
        if url in website_targets:
            passing = (root / "diagnostic-websites-pass").exists()
            status = 200 if passing else 503
            print(f"\nTM_WEBSITE_V1 {website_targets[url]} 200 {status} 0 0.001")
            category = "website-success" if passing else "website-fault-injection"
        elif url == "https://claude.ai/cdn-cgi/trace":
            print("ip=192.0.2.1\nloc=US\n\nTM_IPRISK_V1 trace 200 200 0 0.001")
            category = "synthetic-claude-trace"
        elif url == "https://ip.net.coffee/api/iprisk/192.0.2.1":
            print('{"error":"fixture service unavailable"}\n\nTM_IPRISK_V1 assessment 200 503 0 0.001')
            category = "netcoffee-fault-injection"
        elif url == "https://ping0.cc/ip/192.0.2.1":
            if (root / "ping0-fail").exists():
                record_diagnostic(root, "ping0-fault-injection", url, proxy_port)
                print("Fixture Ping0 unavailable\n\nTM_PING0_V1 assessment 200 503 0 0.001")
                return 0
            delayed = root / "ping0-delay"
            if delayed.exists():
                record_diagnostic(root, "ping0-delayed", url, proxy_port)
                (root / "ping0-delay-started").touch(exist_ok=False)
                deadline = time.monotonic() + 8
                while delayed.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
            else:
                record_diagnostic(root, "ping0-success", url, proxy_port)
            print(ping0_fixture_html() + "\n\nTM_PING0_V1 assessment 200 200 0 0.001")
            return 0
        else:
            print("Fixture refused an unlisted diagnostic command", file=sys.stderr)
            return 126
        record_diagnostic(root, category, url, proxy_port)
        return 0
    print("Fixture refused an unlisted remote command", file=sys.stderr)
    return 126


def reserved_socket():
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)
    return listener


def http_fixture(marker):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = marker.encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def descendant_pids(root_pid):
    rows = subprocess.run(["/bin/ps", "-axo", "pid=,ppid="], capture_output=True,
                          text=True, check=True).stdout.splitlines()
    parents = {int(row.split()[0]): int(row.split()[1]) for row in rows if len(row.split()) == 2}
    descendants = set()
    while True:
        discovered = {pid for pid, parent in parents.items() if parent == root_pid or parent in descendants}
        if discovered <= descendants:
            return descendants
        descendants |= discovered


def stop_owned_process(process):
    if process.poll() is not None:
        return
    descendants = descendant_pids(process.pid)
    process.terminate()
    for pid in descendants:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=4)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=4)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ports_closed(ports):
    for port in ports:
        with socket.socket() as connection:
            connection.settimeout(0.15)
            if connection.connect_ex(("127.0.0.1", port)) == 0:
                return False
    return True


def fixture_ssh_clients(root):
    result = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True,
                            text=True, check=True)
    return [int(line.split()[0]) for line in result.stdout.splitlines()
            if "UserKnownHostsFile=" + str(root) + "/" in line and "/usr/bin/ssh " in line]


def ssh_arguments(root, port, user):
    return ["/usr/bin/ssh", "-F", "/dev/null", "-S", "none", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no", "-o", "CheckHostIP=no",
            "-o", "IdentityAgent=none", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", f"UserKnownHostsFile={root}/known_hosts", "-o", "ConnectTimeout=2",
            "-o", "IdentitiesOnly=yes", "-i", str(root / "client"), "-p", str(port),
            f"{user}@127.0.0.1", "printf CATUNNEL_FIXTURE_READY"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=pathlib.Path, required=True)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    args = parser.parse_args()
    def terminate_fixture(_signal, _frame):
        raise InterruptedError("Fixture interrupted; owned services are being cleaned up")
    signal.signal(signal.SIGTERM, terminate_fixture)
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "suite": "isolated-real-ssh", "platform": platform.mac_ver()[0],
        "architecture": platform.machine(), "status": "failed", "checks": [],
        "scope": "Two disposable macOS sshd servers, real SSH transport and TCP forwarding; lsof listener adapter",
        "publicDiagnostics": "Injected SSH responses only; no public website or Net.Coffee requests",
        "notValidated": ["Linux ss", "Clash", "public API access", "physical sleep and wake"],
    }
    started = time.monotonic()
    temporary_path = None
    try:
        if sys.platform != "darwin":
            raise RuntimeError("The isolated fixture currently requires macOS; no test was run")
        for path in ("/usr/sbin/sshd", "/usr/bin/ssh", "/usr/bin/ssh-keygen", "/usr/sbin/lsof", "/usr/bin/python3"):
            if not os.access(path, os.X_OK):
                raise RuntimeError(f"Fixture prerequisite is unavailable: {path}")
        # sshd StrictModes rejects an authorized_keys ancestor under /private/tmp.
        # The user's private temp directory preserves strict checks without edits.
        with tempfile.TemporaryDirectory(prefix="cati.") as directory:
            root = pathlib.Path(directory).resolve()
            temporary_path = root
            os.chmod(root, 0o700)
            processes, log_handles, servers, reservations, fixture_ports = [], [], [], [], []
            try:
                for name in ("host_a", "host_b", "wrong_host", "client", "rejected_client"):
                    subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)],
                                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                (root / "authorized_keys").write_bytes((root / "client.pub").read_bytes())
                (root / "authorized_keys").chmod(0o600)
                markers = ["catunnel-fixture-a-" + secrets.token_hex(12), "catunnel-fixture-b-" + secrets.token_hex(12)]
                servers = [http_fixture(marker) for marker in markers]
                reservations = [reserved_socket() for _ in range(5)]
                ports = [item.getsockname()[1] for item in reservations]
                fixture = {"root": str(root), "user": pwd.getpwuid(os.getuid()).pw_name,
                           "sshPorts": ports[:2], "localPorts": [server.server_port for server in servers],
                           "remotePorts": ports[2:4], "occupiedPort": ports[4], "markers": markers}
                fixture_ports = ports + fixture["localPorts"]
                (root / "fixture.json").write_text(json.dumps(fixture))
                known_hosts = ""
                for port, name in zip(fixture["sshPorts"], ("host_a", "host_b")):
                    fields = (root / (name + ".pub")).read_text().split()
                    known_hosts += f"[127.0.0.1]:{port} {fields[0]} {fields[1]}\n"
                (root / "known_hosts").write_text(known_hosts)
                (root / "empty_known_hosts").write_text("")
                wrong = (root / "wrong_host.pub").read_text().split()
                (root / "mismatched_known_hosts").write_text(f"[127.0.0.1]:{ports[0]} {wrong[0]} {wrong[1]}\n")
                trust_files = [root / name for name in ("known_hosts", "empty_known_hosts", "mismatched_known_hosts")]
                initial_trust = [digest(path) for path in trust_files]
                force = shlex.join(["/usr/bin/python3", str(pathlib.Path(__file__).resolve()), "--forced-command", str(root)])
                for index, host_name in enumerate(("host_a", "host_b")):
                    config = "\n".join([
                        f"Port {ports[index]}", "ListenAddress 127.0.0.1", f"HostKey {root}/{host_name}",
                        f"PidFile {root}/sshd-{index}.pid", f"AuthorizedKeysFile {root}/authorized_keys",
                        f"AllowUsers {fixture['user']}", "AuthenticationMethods publickey", "PubkeyAuthentication yes",
                        "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no", "UseDNS no",
                        "StrictModes yes", "AllowTcpForwarding remote", "GatewayPorts no", "AllowAgentForwarding no",
                        "X11Forwarding no", "PermitTunnel no", "PermitUserEnvironment no", "PrintMotd no",
                        "MaxAuthTries 2", "LogLevel ERROR", "ForceCommand " + force, "",
                    ])
                    config_path = root / f"sshd-{index}.conf"
                    config_path.write_text(config)
                    subprocess.run(["/usr/sbin/sshd", "-t", "-f", str(config_path)], check=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    reservations[index].close()
                    log = (root / f"sshd-{index}.log").open("wb")
                    log_handles.append(log)
                    processes.append(subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config_path)],
                                                      stdout=log, stderr=log, start_new_session=True))
                for port in fixture["sshPorts"]:
                    for attempt in range(12):
                        ready = subprocess.run(ssh_arguments(root, port, fixture["user"]), capture_output=True,
                                               text=True, timeout=5, check=False)
                        if ready.returncode == 0 and ready.stdout == "CATUNNEL_FIXTURE_READY":
                            break
                        if attempt == 11:
                            raise RuntimeError("Disposable SSH service failed its strict-key readiness check: " + ready.stderr[-1200:])
                        time.sleep(0.15)
                for reservation in reservations[2:4]:
                    reservation.close()
                checks_path = root / "checks.json"
                runner = subprocess.Popen([str(args.binary.resolve()), str(root / "fixture.json"), str(checks_path)],
                                          start_new_session=True)
                processes.append(runner)
                runner.wait(timeout=180)
                if checks_path.exists():
                    report["checks"] = json.loads(checks_path.read_text())
                trust_unchanged = initial_trust == [digest(path) for path in trust_files]
                report["checks"].append({"name": "all private known_hosts files remain byte-for-byte unchanged",
                                         "passed": trust_unchanged, "detail": "SHA-256 comparison"})
                audit_path = root / "diagnostic-audit.jsonl"
                audit = [json.loads(line) for line in audit_path.read_text().splitlines()] if audit_path.exists() else []
                report["injectedDiagnostics"] = audit
                allowed_urls = {
                    "https://api.openai.com/v1/models", "https://api.anthropic.com/v1/models",
                    "https://www.google.com/generate_204", "https://claude.ai/cdn-cgi/trace",
                    "https://ip.net.coffee/api/iprisk/192.0.2.1", "https://ping0.cc/ip/192.0.2.1",
                }
                expected_audit = bool(audit) and all(
                    not entry["executed_public_request"] and entry["url"] in allowed_urls
                    and entry["proxy_port"] in fixture["remotePorts"] for entry in audit)
                report["checks"].append({"name": "diagnostics used only controlled SSH fault-injection replies",
                                         "passed": expected_audit, "detail": f"{len(audit)} allowlisted fixture replies"})
                report["status"] = "passed" if runner.returncode == 0 and all(item["passed"] for item in report["checks"]) else "failed"
            except BaseException:
                report["fixtureLogs"] = [path.read_text(errors="replace")[-2000:].replace(str(root), "<fixture>")
                                         for path in sorted(root.glob("sshd-*.log"))]
                raise
            finally:
                cleanup_errors = []
                for process in reversed(processes):
                    try:
                        stop_owned_process(process)
                    except Exception as error:
                        cleanup_errors.append(str(error))
                for log in log_handles:
                    log.close()
                for reservation in reservations:
                    reservation.close()
                for server in servers:
                    server.shutdown()
                    server.server_close()
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    listeners_closed = ports_closed(fixture_ports)
                    clients_closed = not fixture_ssh_clients(root)
                    if listeners_closed and clients_closed:
                        break
                    time.sleep(0.1)
                report["checks"].extend([
                    {"name": "all disposable fixture TCP listeners are closed", "passed": listeners_closed,
                     "detail": "loopback connection checks after cleanup"},
                    {"name": "no SSH clients using the private fixture trust store remain", "passed": clients_closed,
                     "detail": "bounded owned-fixture process check after stopping disposable servers"},
                ])
                if cleanup_errors:
                    report["cleanupErrors"] = cleanup_errors
                if not listeners_closed or not clients_closed or cleanup_errors:
                    report["status"] = "failed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = str(error) or type(error).__name__
    report["temporaryFixtureRemoved"] = temporary_path is None or not temporary_path.exists()
    report["durationSeconds"] = round(time.monotonic() - started, 3)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"Isolated real SSH result: {report['status']}; report: {report_path}")
    return 0 if report["status"] == "passed" and report["temporaryFixtureRemoved"] else 1


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--forced-command":
        raise SystemExit(force_command(pathlib.Path(sys.argv[2])))
    raise SystemExit(main())
