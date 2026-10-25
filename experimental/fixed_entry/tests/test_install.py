import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fixed_entry_install", ROOT / "install.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)
PAYLOAD = (ROOT / "relay.py").read_bytes()
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cti.", dir="/tmp")
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "h ome"
        self.home.mkdir(mode=0o700)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        self.target = self.home / ".catunnel" / "fixed-entry" / str(self.port)
        self.children = []
        real_popen = subprocess.Popen

        def track(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            self.children.append(child)
            return child

        self.popen = mock.patch.object(installer.subprocess, "Popen", side_effect=track)
        self.popen.start()

    def tearDown(self):
        self.popen.stop()
        for child in self.children:
            installer.terminate_owned(child)
        self.temporary.cleanup()

    def install(self, payload=PAYLOAD, digest=DIGEST):
        return installer.install(self.port, digest, payload, self.home)

    def error(self, code, operation=None):
        with self.assertRaisesRegex(installer.InstallError, "^" + code + "$"):
            (self.install if operation is None else operation)()

    def stop(self):
        for child in self.children:
            installer.terminate_owned(child)

    def status(self):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(2)
            connection.connect(str(self.target / "r" / "control.sock"))
            connection.sendall(b'{"op":"status"}\n')
            return json.loads(connection.recv(4096))

    def test_install_private_paths_and_reuse_preserve_pid_epoch_and_generation(self):
        first = self.install()
        before = self.status()
        second = self.install()
        self.assertFalse(first["reused"])
        self.assertTrue(second["reused"])
        self.assertEqual(first["pid"], second["pid"])
        self.assertEqual(before, self.status())
        self.assertEqual(first["helper_path"], str(self.target / "relay.py"))
        self.assertEqual(first["runtime_path"], str(self.target / "r"))
        self.assertEqual(first["sha256"], DIGEST)
        for path in (self.target, self.target / "r", self.target.parent, self.target.parent.parent):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        for path in (self.target / "relay.py", self.target / "manifest.json", self.target / "relay.log"):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(path.stat().st_nlink, 1)
        self.assertEqual(len(self.children), 1)

    def test_clean_stopped_install_can_restart_without_rewriting_payload(self):
        first = self.install()
        original = (self.target / "relay.py").stat().st_ino
        self.stop()
        second = self.install()
        self.assertNotEqual(first["pid"], second["pid"])
        self.assertFalse(second["reused"])
        self.assertEqual((self.target / "relay.py").stat().st_ino, original)

    def test_bad_payload_and_truncation_do_not_create_install_directories(self):
        self.error("payload_hash_mismatch", lambda: self.install(PAYLOAD[:-1]))
        self.error("payload_invalid", lambda: self.install(b"", hashlib.sha256(b"").hexdigest()))
        huge = b"x" * (installer.PAYLOAD_LIMIT + 1)
        self.error("payload_too_large", lambda: self.install(huge, hashlib.sha256(huge).hexdigest()))
        invalid = b"invalid python !!!"
        self.error("payload_invalid", lambda: self.install(invalid, hashlib.sha256(invalid).hexdigest()))
        self.assertFalse((self.home / ".catunnel").exists())

    def test_occupied_port_is_not_touched(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.port))
            listener.listen()
            self.error("port_in_use")
            with socket.create_connection(("127.0.0.1", self.port), timeout=1):
                accepted, _ = listener.accept()
                accepted.close()
        self.assertFalse(self.target.exists())
        self.assertEqual(self.children, [])

    def test_unknown_existing_directory_and_files_are_preserved(self):
        self.target.mkdir(parents=True, mode=0o700)
        self.target.parent.chmod(0o700)
        self.target.parent.parent.chmod(0o700)
        self.error("installation_unknown")
        unknown = self.target / "user-owned"
        unknown.write_text("keep")
        self.error("installation_unknown")
        self.assertEqual(unknown.read_text(), "keep")

    def test_symlink_install_root_is_rejected(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir(mode=0o700)
        (self.home / ".catunnel").symlink_to(elsewhere, target_is_directory=True)
        self.error("directory_unsafe")
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_wrong_directory_modes_and_owner_are_rejected(self):
        (self.home / ".catunnel").mkdir(mode=0o755)
        self.error("directory_unsafe")
        (self.home / ".catunnel").chmod(0o700)
        with mock.patch.object(installer.os, "getuid", return_value=os.getuid() + 1):
            self.error("home_unsafe")

    def test_manifest_hash_mode_and_hardlinks_are_checked_without_restarting(self):
        first = self.install()
        helper = self.target / "relay.py"
        helper.write_bytes(PAYLOAD + b"\n")
        self.error("installation_mismatch")
        helper.write_bytes(PAYLOAD)
        helper.chmod(0o644)
        self.error("file_unsafe")
        helper.chmod(0o600)
        os.link(helper, self.root / "second-link")
        self.error("file_unsafe")
        (self.root / "second-link").unlink()
        manifest = self.target / "manifest.json"
        content = json.loads(manifest.read_text())
        content["port"] += 1
        manifest.write_text(json.dumps(content))
        self.error("installation_mismatch")
        self.assertIsNone(self.children[0].poll())
        self.assertEqual(first["pid"], self.children[0].pid)
        self.assertEqual(len(self.children), 1)

    def test_helper_symlink_is_rejected_without_following_it(self):
        self.install()
        helper = self.target / "relay.py"
        helper.unlink()
        helper.symlink_to(ROOT / "relay.py")
        self.error("file_unsafe")
        self.assertIsNone(self.children[0].poll())

    def test_stale_runtime_refuses_restart_and_keeps_evidence(self):
        self.install()
        self.stop()
        evidence = self.target / "r" / "ready.json"
        evidence.write_text('{"pid":1}')
        evidence.chmod(0o600)
        self.error("runtime_not_clean")
        self.assertEqual(evidence.read_text(), '{"pid":1}')
        self.assertEqual(len(self.children), 1)

    def test_concurrent_installer_lock_is_not_deleted_or_replaced(self):
        self.install()
        lock = self.target.parent / (str(self.port) + ".install.lock")
        inode = lock.stat().st_ino
        with lock.open("r+b") as source:
            fcntl.flock(source.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.error("install_busy")
            self.assertEqual(lock.stat().st_ino, inode)
        self.assertTrue(self.install()["reused"])

    def test_invalid_peer_pid_and_ready_metadata_do_not_signal_existing_helper(self):
        self.install()
        with mock.patch.object(installer, "peer_pid", return_value=1):
            self.error("helper_identity_mismatch")
        ready = self.target / "r" / "ready.json"
        value = json.loads(ready.read_text())
        value["pid"] = 1
        ready.write_text(json.dumps(value))
        self.error("helper_identity_mismatch")
        self.assertIsNone(self.children[0].poll())

    def test_active_generation_refuses_without_begin_or_process_change(self):
        self.install()
        real_json = installer.json.loads

        def active_status(value, *args, **kwargs):
            data = real_json(value, *args, **kwargs)
            if isinstance(data, dict) and "active_generation" in data:
                data["active_generation"] = 7
            return data

        before = self.status()
        with mock.patch.object(installer.json, "loads", side_effect=active_status):
            self.error("active_entry")
        self.assertEqual(before, self.status())
        self.assertEqual(len(self.children), 1)
        self.assertIsNone(self.children[0].poll())

    def test_start_failure_retains_safe_retryable_installation(self):
        failing = b"raise SystemExit(3)\n"
        digest = hashlib.sha256(failing).hexdigest()
        self.error("start_failed", lambda: self.install(failing, digest))
        self.assertEqual((self.target / "relay.py").read_bytes(), failing)
        self.assertEqual(list((self.target / "r").iterdir()), [])
        self.assertIsNotNone(self.children[0].poll())
        self.error("start_failed", lambda: self.install(failing, digest))

    def test_launch_exception_does_not_delete_existing_user_state(self):
        with mock.patch.object(installer.subprocess, "Popen", side_effect=OSError("fixture")):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual((self.target / "relay.py").read_bytes(), PAYLOAD)
        self.assertTrue((self.target / "manifest.json").exists())
        self.assertFalse((self.target / "r" / "ready.json").exists())
        self.assertTrue(self.install()["ok"])

    def test_initial_write_failure_removes_only_owned_staging_and_retries(self):
        original = installer.write_new

        def fail_manifest(path, data, owned=None):
            if path.name == "manifest.json":
                raise OSError("fixture write failure")
            return original(path, data, owned)

        with mock.patch.object(installer, "write_new", side_effect=fail_manifest):
            with self.assertRaises(OSError):
                self.install()
        self.assertFalse(self.target.exists())
        self.assertTrue(self.install()["ok"])

    def test_new_helper_that_became_active_is_not_terminated(self):
        original = installer.helper_status

        def became_active(*args, **kwargs):
            original(*args, **kwargs)
            installer.fail("active_entry")

        with mock.patch.object(installer, "helper_status", side_effect=became_active):
            self.error("active_entry")
        self.assertIsNone(self.children[0].poll())
        self.assertTrue(self.install()["reused"])

    def test_cli_errors_are_one_json_line_without_traceback_or_payload(self):
        script = (ROOT / "install.py").read_text()
        for arguments, data, expected in [
            (["--port", str(self.port), "--sha256", DIGEST], b"secret payload", "payload_hash_mismatch"),
            (["--port", "bad", "--sha256", DIGEST], b"", "arguments_invalid"),
            (["--help"], b"", "arguments_invalid"),
        ]:
            process = subprocess.run([sys.executable, "-c", script] + arguments, input=data,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=dict(os.environ, HOME=str(self.home)), timeout=5)
            self.assertEqual(process.returncode, 1)
            self.assertEqual(process.stderr, b"")
            self.assertEqual(process.stdout.count(b"\n"), 1)
            self.assertEqual(json.loads(process.stdout), {"version": 1, "ok": False, "error": expected})
        self.assertFalse((self.home / ".catunnel").exists())


if __name__ == "__main__":
    unittest.main()
