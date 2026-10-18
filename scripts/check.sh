#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swift-common.sh"

# These checks use fixtures and owned local child processes; no SSH or HTTP requests.
swift run "${SWIFT_PACKAGE_ARGS[@]}" --configuration debug TunnelCoreChecks
