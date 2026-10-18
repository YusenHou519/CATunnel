#!/bin/bash
# Shared local paths keep build output inside this checkout.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

SWIFT_PACKAGE_ARGS=(
  --package-path "$PROJECT_ROOT"
  --scratch-path "$PROJECT_ROOT/.build"
  --cache-path "$PROJECT_ROOT/.build/package-cache"
  --config-path "$PROJECT_ROOT/.build/package-config"
)

# Some restricted development environments cannot nest SwiftPM's manifest sandbox.
# Regular local builds retain the default sandbox behavior.
if [[ "${CATUNNEL_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  SWIFT_PACKAGE_ARGS+=(--disable-sandbox)
fi
