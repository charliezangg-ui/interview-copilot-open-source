#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-toolchain.sh
echo "macOS: $(sw_vers -productVersion) ($(uname -m))"
xcrun swift --version
python3 --version
echo "Xcode: $DEVELOPER_DIR"
IDENTITY="${COPILOT_SIGNING_IDENTITY:-InterviewCopilot Local Development}"
if security find-identity -v -p codesigning | /usr/bin/grep -Fq -- "$IDENTITY"; then
  echo "Local signing: ready"
else
  echo "Local signing: not configured; see docs/INSTALL.md before building an .app"
fi
echo "Codex: check with the app's connection button, or run swift run CodexConnectionCheck"
echo "Voice model: download/verify in app settings"
echo "Environment check complete. No accounts, permissions or certificates changed."
