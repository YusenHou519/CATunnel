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
            "CATunnel.app/Contents/Resources/AppIcon.icns", "CATunnel.app/Contents/_CodeSignature/CodeResources"]
regular = stat.S_IFREG | 0o644
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
with tempfile.TemporaryDirectory(prefix="catunnel-verifier-fixtures-") as temporary:
    directory = Path(temporary)
    for name, entries, expected in cases:
        archive = directory / (name + ".zip")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(archive, "w") as package:
                for filename, mode in entries:
                    item = zipfile.ZipInfo(filename)
                    item.create_system = 3
                    item.external_attr = mode << 16
                    package.writestr(item, b"fixture")
        output = directory / (name + "-report")
        result = subprocess.run(["bash", str(script), str(archive), str(output)], capture_output=True, text=True)
        report = json.loads((output / "release-verification.json").read_text())
        if result.returncode != 1 or report.get("success") is not False or expected not in report.get("error", ""):
            raise SystemExit(f"FAIL {name}: {result.returncode}, {report}")
        print(f"PASS {name}")
print(f"PASS: {len(cases)} archive rejection checks; temporary fixtures removed.")
PY
