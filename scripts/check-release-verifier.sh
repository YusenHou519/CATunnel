#!/bin/bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$SCRIPT_DIRECTORY/verify-release.sh" <<'PY'
from pathlib import Path
import json
import stat
import subprocess
import sys
import tempfile
import warnings
import zipfile

script = Path(sys.argv[1]).resolve()
required = ["CATunnel.app/Contents/MacOS/CATunnel", "CATunnel.app/Contents/Info.plist",
            "CATunnel.app/Contents/Resources/AppIcon.icns", "CATunnel.app/Contents/_CodeSignature/CodeResources",
            "CATunnel.app/Contents/Resources/FixedEntry/relay.py", "CATunnel.app/Contents/Resources/FixedEntry/install.py"]
regular = stat.S_IFREG | 0o644
valid_entries = [(name, stat.S_IFREG | 0o755 if name == required[0] else regular) for name in required]
cases = [
    ("parent-traversal", [("CATunnel.app/../../escape", regular)], "unsafe path"),
    ("absolute-path", [("/tmp/escape", regular)], "unsafe path"),
    ("backslash-path", [("CATunnel.app/Contents\\escape", regular)], "unsafe path"),
    ("symlink", [("CATunnel.app/link", stat.S_IFLNK | 0o777)], "symlink or special"),
    ("named-pipe", [("CATunnel.app/pipe", stat.S_IFIFO | 0o600)], "symlink or special"),
    ("world-write", [("CATunnel.app/write", stat.S_IFREG | 0o666)], "unsafe file permissions"),
    ("unexpected-root", [("Other.app/file", regular)], "unexpected top-level"),
    ("duplicate", [("CATunnel.app/file", regular)] * 2, "duplicate or case-colliding"),
    ("case-collision", [("CATunnel.app/File", regular), ("CATunnel.app/file", regular)], "duplicate or case-colliding"),
    ("missing-bundle", [("CATunnel.app/file", regular)], "missing required"),
    ("nonexecutable", [(name, regular) for name in required], "executable permission"),
]
for resource in required[-2:]:
    label = Path(resource).stem
    cases.append(("missing-" + label, [(name, mode) for name, mode in valid_entries if name != resource], "missing required"))
    cases.append(("empty-" + label, [(name, mode, b"" if name == resource else b"fixture") for name, mode in valid_entries],
                  "installer resource is empty"))
    cases.append(("unreadable-" + label, [(name, stat.S_IFREG | 0o200 if name == resource else mode) for name, mode in valid_entries],
                  "installer resource is not a readable regular file"))
with tempfile.TemporaryDirectory(prefix="catunnel-verifier-fixtures-") as temporary:
    directory = Path(temporary)
    for name, entries, expected in cases:
        archive = directory / (name + ".zip")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(archive, "w") as package:
                for entry in entries:
                    filename, mode = entry[:2]
                    payload = entry[2] if len(entry) == 3 else b"fixture"
                    item = zipfile.ZipInfo(filename)
                    item.create_system = 3
                    item.external_attr = mode << 16
                    package.writestr(item, payload)
        output = directory / (name + "-report")
        result = subprocess.run(["bash", str(script), str(archive), str(output)], capture_output=True, text=True)
        report = json.loads((output / "release-verification.json").read_text())
        if result.returncode != 1 or report.get("success") is not False or expected not in report.get("error", ""):
            raise SystemExit(f"FAIL {name}: {result.returncode}, {report}")
        print(f"PASS {name}")
print(f"PASS: {len(cases)} archive rejection checks; temporary fixtures removed.")
PY
