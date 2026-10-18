#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: bash scripts/package-release.sh

Build a native-architecture macOS preview ZIP with RELEASE.json metadata.
Existing release directories are never overwritten. No app is launched.

Optional environment:
  CATUNNEL_RELEASE_DIR       Output parent (default: verification/release).
  CATUNNEL_EXPECT_ARCH       Fail if the built binary differs from arm64/x86_64.
  CATUNNEL_SIGNING_IDENTITY  codesign identity (default: - for ad-hoc).
  CATUNNEL_NOTARY_PROFILE    Existing notarytool Keychain profile. Setting it
                            explicitly opts into submission to Apple, requires
                            Developer ID signing, and waits for acceptance.
USAGE
  exit 0
fi
if [[ "$#" -ne 0 ]]; then
  printf 'Unexpected argument. Use --help.\n' >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Release packaging requires macOS.\n' >&2
  exit 1
fi

PLIST="$PROJECT_ROOT/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD" =~ ^[0-9]+$ ]]; then
  printf 'Release version must be major.minor.patch and build must be numeric.\n' >&2
  exit 1
fi
NATIVE_ARCH="$(uname -m)"
case "$NATIVE_ARCH" in
  arm64|x86_64) ;;
  *) printf 'Unsupported native architecture: %s\n' "$NATIVE_ARCH" >&2; exit 1 ;;
esac
EXPECTED_ARCH="${CATUNNEL_EXPECT_ARCH:-$NATIVE_ARCH}"
if [[ "$EXPECTED_ARCH" != "$NATIVE_ARCH" ]]; then
  printf 'Expected architecture %s does not match native build host %s.\n' "$EXPECTED_ARCH" "$NATIVE_ARCH" >&2
  exit 1
fi
CHANNEL="preview"
SIGNING_IDENTITY="${CATUNNEL_SIGNING_IDENTITY:--}"
if [[ -n "${CATUNNEL_NOTARY_PROFILE:-}" ]]; then
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    printf 'Notarization requires an explicit Developer ID signing identity.\n' >&2
    exit 1
  fi
  xcrun --find notarytool >/dev/null
  xcrun --find stapler >/dev/null
  CHANNEL="notarized"
fi
RELEASE_NAME="CATunnel-$VERSION-build$BUILD-macos-$NATIVE_ARCH-$CHANNEL"
OUTPUT_ROOT="${CATUNNEL_RELEASE_DIR:-$PROJECT_ROOT/verification/release}"
mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"
FINAL_DIR="$OUTPUT_ROOT/$RELEASE_NAME"
if [[ -e "$FINAL_DIR" || -L "$FINAL_DIR" ]]; then
  printf 'Release output already exists; choose a new output parent: %s\n' "$FINAL_DIR" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "$OUTPUT_ROOT/.catunnel-package.XXXXXX")"
FINAL_RESERVED=0
COMPLETED=0
cleanup() {
  rm -rf "$STAGING_DIR"
  if [[ "$FINAL_RESERVED" == "1" && "$COMPLETED" == "0" ]]; then
    rm -rf "$FINAL_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
CATUNNEL_OUTPUT_DIR="$STAGING_DIR" bash "$PROJECT_ROOT/scripts/build-app.sh"
APP="$STAGING_DIR/CATunnel.app"
ACTUAL_ARCH="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/CATunnel")"
if [[ "$ACTUAL_ARCH" != "$EXPECTED_ARCH" ]]; then
  printf 'Built architecture %s does not match expected %s.\n' "$ACTUAL_ARCH" "$EXPECTED_ARCH" >&2
  exit 1
fi

SIGNATURE="$(/usr/bin/codesign -d --verbose=4 "$APP" 2>&1)"
SIGNING_KIND="ad-hoc"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNING_KIND="signed"
fi
if [[ "$CHANNEL" == "notarized" ]]; then
  if [[ "$SIGNATURE" != *"Authority=Developer ID Application:"* ]]; then
    printf 'Notarization requires a Developer ID Application signature.\n' >&2
    exit 1
  fi
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING_DIR/notarization-upload.zip"
  xcrun notarytool submit "$STAGING_DIR/notarization-upload.zip" \
    --keychain-profile "$CATUNNEL_NOTARY_PROFILE" --wait --output-format json >"$STAGING_DIR/notarization.json"
  python3 - "$STAGING_DIR/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
if result.get("status") != "Accepted":
    raise SystemExit("Notarization was not accepted; no release was produced.")
PY
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  /usr/sbin/spctl --assess --type execute --verbose "$APP"
  rm "$STAGING_DIR/notarization-upload.zip"
fi
/usr/bin/codesign --verify --deep --strict "$APP"

python3 - "$PROJECT_ROOT" "$APP" "$STAGING_DIR/RELEASE.json" "$ACTUAL_ARCH" "$SIGNING_KIND" "$CHANNEL" <<'PY'
import json, pathlib, plistlib, subprocess, sys

root, app, destination, architecture, signing, channel = sys.argv[1:]
def command(*args):
    return subprocess.check_output(args, cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
with open(pathlib.Path(app) / "Contents/Info.plist", "rb") as handle:
    info = plistlib.load(handle)
try:
    commit = command("git", "rev-parse", "--verify", "HEAD")
except subprocess.CalledProcessError:
    commit = None
try:
    dirty = bool(command("git", "status", "--porcelain", "--untracked-files=normal"))
except subprocess.CalledProcessError:
    dirty = None
metadata = {
    "schemaVersion": 1,
    "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"],
    "bundleIdentifier": info["CFBundleIdentifier"],
    "architecture": architecture,
    "deploymentTarget": info["LSMinimumSystemVersion"],
    "channel": channel,
    "signing": signing,
    "notarized": channel == "notarized",
    "source": {"commit": commit, "dirty": dirty},
    "buildHost": {
        "macosVersion": command("sw_vers", "-productVersion"),
        "swiftVersion": command("swift", "--version"),
    },
    "validationNote": "Architecture is inspected from this binary. Deployment target is not proof of runtime compatibility. See docs/VALIDATION.md for test evidence.",
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(metadata, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING_DIR/$RELEASE_NAME.zip"
# mkdir is the final collision check, including concurrent packaging attempts.
mkdir "$FINAL_DIR"
FINAL_RESERVED=1
/usr/bin/ditto "$STAGING_DIR" "$FINAL_DIR"
COMPLETED=1
printf 'Release directory: %s\n' "$FINAL_DIR"
