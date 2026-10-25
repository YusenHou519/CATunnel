#!/bin/bash
set -euo pipefail

# Verify a release without installing it or launching its normal mode.
exec python3 - "$@" <<'PY'
import argparse
import datetime
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import zipfile


def run(*arguments, timeout=30):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise ValueError(f"{Path(arguments[0]).name} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout + result.stderr


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inspect_archive(archive):
    names = set()
    total = 0
    executable = "CATunnel.app/Contents/MacOS/CATunnel"
    installer_resources = {"CATunnel.app/Contents/Resources/FixedEntry/relay.py",
                           "CATunnel.app/Contents/Resources/FixedEntry/install.py"}
    required = {executable, "CATunnel.app/Contents/Info.plist",
                "CATunnel.app/Contents/Resources/AppIcon.icns",
                "CATunnel.app/Contents/_CodeSignature/CodeResources"} | installer_resources
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        require(0 < len(entries) <= 10000, "Archive has an unexpected number of entries.")
        for entry in entries:
            name = entry.filename
            path = PurePosixPath(name)
            parts = name.rstrip("/").split("/")
            require(not path.is_absolute() and "\\" not in name
                    and all(part not in ("", ".", "..") for part in parts)
                    and not any(ord(char) < 32 or ord(char) == 127 for char in name),
                    "Archive contains an unsafe path.")
            require(parts[0] in ("CATunnel.app", "__MACOSX"), "Archive contains an unexpected top-level item.")
            normalized = name.rstrip("/").casefold()
            require(normalized not in names, "Archive contains duplicate or case-colliding paths.")
            names.add(normalized)
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR), "Archive contains a symlink or special file.")
            require(not mode & (stat.S_ISUID | stat.S_ISGID | stat.S_IWOTH), "Archive contains unsafe file permissions.")
            require(not entry.flag_bits & 1, "Encrypted archive entries are unsupported.")
            require(entry.file_size <= 256 * 1024 * 1024, "An archive entry exceeds the size limit.")
            total += entry.file_size
            require(total <= 512 * 1024 * 1024, "Archive exceeds the expanded-size limit.")
            if name == executable:
                require(mode & stat.S_IXUSR, "App executable is missing its executable permission.")
            if name in installer_resources:
                require(kind in (0, stat.S_IFREG) and not entry.is_dir() and mode & stat.S_IRUSR,
                        "Fixed-entry installer resource is not a readable regular file.")
                require(entry.file_size > 0, "Fixed-entry installer resource is empty.")
        require(required.issubset({entry.filename for entry in entries}), "Archive is missing required app bundle files.")
        require(package.testzip() is None, "Archive has a corrupt entry.")
    return {"entries": len(entries), "expandedBytes": total}


def inspect_bundle(bundle):
    for item in bundle.rglob("*"):
        require(not item.is_symlink(), "Extracted app contains a symlink.")
        mode = item.stat().st_mode
        require(stat.S_ISREG(mode) or stat.S_ISDIR(mode), "Extracted app contains a special file.")
        require(not mode & (stat.S_ISUID | stat.S_ISGID | stat.S_IWOTH), "Extracted app has unsafe permissions.")
    for name in ("relay.py", "install.py"):
        resource = bundle / "Contents/Resources/FixedEntry" / name
        require(resource.is_file() and os.access(resource, os.R_OK),
                "Fixed-entry installer resource is missing or unreadable.")
        with resource.open("rb") as source:
            require(bool(source.read(1)), "Fixed-entry installer resource is empty.")
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "local.catunnel.CATunnel", "Unexpected bundle identifier.")
    require(info.get("CFBundleExecutable") == "CATunnel" and info.get("CFBundlePackageType") == "APPL",
            "Unexpected app bundle metadata.")
    require(info.get("LSUIElement") is True, "App is not configured as a menu-bar application.")
    require(re.fullmatch(r"\d+\.\d+\.\d+", info.get("CFBundleShortVersionString", "")), "Invalid release version.")
    require(re.fullmatch(r"\d+", info.get("CFBundleVersion", "")), "Invalid build version.")
    minimum = info.get("LSMinimumSystemVersion", "")
    require(re.fullmatch(r"\d+\.\d+(?:\.\d+)?", minimum), "Missing minimum macOS version.")
    executable = bundle / "Contents/MacOS/CATunnel"
    require(os.access(executable, os.X_OK), "Extracted app executable cannot be executed.")
    data = executable.read_bytes()
    require(re.search(rb"/(?:Users|home)/[^/\x00\s]+/", data) is None,
            "App executable contains a personal build-directory path. Strip or remap build paths before signing.")
    architectures = run("/usr/bin/lipo", "-archs", str(executable)).strip().split()
    require(len(architectures) == 1 and architectures[0] in ("arm64", "x86_64"), "Unexpected Mach-O architecture.")
    load_commands = run("/usr/bin/otool", "-l", str(executable))
    targets = re.findall(r"(?s)cmd LC_BUILD_VERSION\s+(?:(?!Load command).)*?\bminos ([\d.]+)", load_commands)
    targets += re.findall(r"(?s)cmd LC_VERSION_MIN_MACOSX\s+(?:(?!Load command).)*?\bversion ([\d.]+)", load_commands)
    def version_parts(value):
        return tuple((value.split(".") + ["0", "0"])[:3])
    require(len(targets) == 1 and version_parts(targets[0]) == version_parts(minimum),
            "Mach-O deployment target disagrees with Info.plist.")
    linked = run("/usr/bin/otool", "-L", str(executable)).splitlines()[1:]
    require(all(line.strip().startswith(("/usr/lib/", "/System/Library/", "@rpath/", "@executable_path/"))
                for line in linked if line.strip()), "App links to a library outside system or bundle paths.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle))
    signature = run("/usr/bin/codesign", "-dv", "--verbose=2", str(bundle))
    adhoc = "Signature=adhoc" in signature
    team_match = re.search(r"^TeamIdentifier=(.+)$", signature, re.MULTILINE)
    return {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "bundleIdentifier": info["CFBundleIdentifier"], "architecture": architectures[0],
            "deploymentTarget": minimum, "signature": "ad-hoc" if adhoc else "certificate",
            "teamIdentifier": team_match.group(1) if team_match else None,
            "signatureVerified": True, "notarizationChecked": False}


def check_manifest(archive, bundle_info):
    manifest_path = archive.parent / "RELEASE.json"
    if not manifest_path.exists():
        return "not provided"
    require(manifest_path.is_file() and not manifest_path.is_symlink() and manifest_path.stat().st_size < 65536,
            "Release metadata is not a small regular file.")
    metadata = json.loads(manifest_path.read_text())
    for field in ("version", "build", "bundleIdentifier", "architecture", "deploymentTarget"):
        require(str(metadata.get(field)) == str(bundle_info[field]), f"Release metadata disagrees with the app: {field}.")
    return "matches app bundle"


def run_ui_check(bundle, report_directory):
    ui_directory = report_directory / "ui"
    require(not ui_directory.exists(), "UI output directory already exists; choose a new report directory.")
    ui_directory.mkdir()
    ui_report = ui_directory / "report.json"
    executable = bundle / "Contents/MacOS/CATunnel"
    with (ui_directory / "output.log").open("w") as output:
        process = subprocess.Popen([str(executable), "--ui-check", str(ui_report)],
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            result = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            raise ValueError("Offline UI verification timed out; only its owned process group was stopped.")
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
    require(result == 0 and ui_report.is_file(), "Offline UI verification failed; inspect ui/output.log.")
    result = json.loads(ui_report.read_text())
    checks = result.get("checks", {})
    require(result.get("success") is True and checks and all(value is True for value in checks.values()),
            "Offline UI report contains failed checks.")
    require(result.get("mode") == "offline-ui-check" and result.get("realSSHConnections") == 0
            and result.get("realProxyRequests") == 0, "UI report is not an offline verification result.")
    return {"status": "passed", "checks": len(checks), "report": "ui/report.json",
            "realSSHConnections": 0, "realProxyRequests": 0, "ownedProcessExited": True}


parser = argparse.ArgumentParser(description="Inspect and safely extract a CATunnel release without installing it.")
parser.add_argument("archive", type=Path)
parser.add_argument("report_directory", type=Path, nargs="?",
                    help="New report directory; defaults to a temporary directory.")
parser.add_argument("--ui-check", action="store_true",
                    help="Also run the extracted app's offline UI checks (requires a graphical macOS session).")
arguments = parser.parse_args()
archive = arguments.archive.expanduser().resolve()
report_directory = arguments.report_directory.expanduser().resolve() if arguments.report_directory else Path(tempfile.mkdtemp(prefix="catunnel-release-report-"))
report_directory.mkdir(parents=True, exist_ok=True)
report_path = report_directory / "release-verification.json"
if report_path.exists():
    parser.error("The report already exists; choose a new report directory.")
report = {"schemaVersion": 1, "archive": archive.name,
          "completedAt": None, "success": False,
          "ui": {"status": "not requested"},
          "cleanup": {"temporaryExtractionRemoved": None},
          "scope": "Temporary extraction and optional offline UI checks; no installation, normal app launch, or network tests."}
extraction_directory = None
try:
    require(sys.platform == "darwin", "Release verification requires macOS.")
    require(archive.is_file() and archive.suffix.lower() == ".zip", "Provide an existing ZIP release archive.")
    report["archiveInspection"] = inspect_archive(archive)
    with tempfile.TemporaryDirectory(prefix="catunnel-release-extract-") as temporary:
        extraction_directory = Path(temporary)
        extracted = Path(temporary) / "extracted"
        extracted.mkdir(mode=0o700)
        run("/usr/bin/ditto", "-x", "-k", str(archive), str(extracted))
        bundle = extracted / "CATunnel.app"
        report["bundle"] = inspect_bundle(bundle)
        report["releaseMetadata"] = check_manifest(archive, report["bundle"])
        if arguments.ui_check:
            report["ui"] = {"status": "running"}
            report["ui"] = run_ui_check(bundle, report_directory)
    report["success"] = True
except (OSError, ValueError, KeyError, RuntimeError, zipfile.BadZipFile, subprocess.SubprocessError, KeyboardInterrupt) as error:
    report["error"] = str(error) or "Verification was interrupted."
finally:
    if extraction_directory is not None:
        report["cleanup"]["temporaryExtractionRemoved"] = not extraction_directory.exists()
        if not report["cleanup"]["temporaryExtractionRemoved"]:
            report["success"] = False
            report["error"] = "Temporary extraction was not removed."
    if report["ui"]["status"] == "running":
        report["ui"] = {"status": "failed"}
    report["completedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
print(f"{'PASS' if report['success'] else 'FAIL'}: {report_path}")
if not report["success"]:
    print(report["error"], file=sys.stderr)
sys.exit(0 if report["success"] else 1)
PY
