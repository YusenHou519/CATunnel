#!/bin/bash
# Explicit, isolated real SSH checks. No real servers, user keys, or proxy needed.
set -euo pipefail
source "$(dirname "$0")/swift-common.sh"

REPORT="$PROJECT_ROOT/verification/integration/report.json"
if [[ $# -eq 2 && "$1" == "--output" ]]; then
  REPORT="$2"
elif [[ $# -ne 0 ]]; then
  printf 'Usage: bash scripts/check-integration.sh [--output REPORT.json]\n' >&2
  exit 2
fi
swift build "${SWIFT_PACKAGE_ARGS[@]}" --configuration debug --product TunnelIntegrationChecks
BIN_DIRECTORY="$(swift build "${SWIFT_PACKAGE_ARGS[@]}" --configuration debug --show-bin-path)"
python3 "$PROJECT_ROOT/scripts/fixtures/ssh_fixture.py" \
  --binary "$BIN_DIRECTORY/TunnelIntegrationChecks" --report "$REPORT"
