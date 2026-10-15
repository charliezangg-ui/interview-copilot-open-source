#!/bin/bash
# Source from build/test scripts. Respect an explicitly selected Xcode.
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Interview Copilot requires macOS 15 or later." >&2
  exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 15 ]; then
  echo "macOS 15 or later is required." >&2
  exit 1
fi
if [ -z "${DEVELOPER_DIR:-}" ]; then
  COPILOT_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [ ! -d "$COPILOT_DEVELOPER_DIR/Platforms/MacOSX.platform" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    COPILOT_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  export DEVELOPER_DIR="$COPILOT_DEVELOPER_DIR"
fi
if [ ! -d "$DEVELOPER_DIR/Platforms/MacOSX.platform" ]; then
  echo "Install full Xcode, open it once, then select it with DEVELOPER_DIR. XCTest is required." >&2
  exit 1
fi
COPILOT_SWIFT_MAJOR="$(xcrun swift --version | sed -nE 's/.*Swift version ([0-9]+).*/\1/p' | head -1)"
if [ -z "$COPILOT_SWIFT_MAJOR" ] || [ "$COPILOT_SWIFT_MAJOR" -lt 6 ]; then
  echo "Swift 6 or later is required." >&2
  exit 1
fi
