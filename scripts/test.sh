#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# XCTest is shipped with Xcode, not every Command Line Tools installation.
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
swift test
