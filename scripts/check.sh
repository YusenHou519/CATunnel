#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swift-common.sh"

# These checks use local fixtures, including loopback TCP, but no SSH or external requests.
swift run "${SWIFT_PACKAGE_ARGS[@]}" --configuration debug TunnelCoreChecks
