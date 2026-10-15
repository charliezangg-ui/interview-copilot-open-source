#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-toolchain.sh
python3 scripts/check-public-source.py
# Ordinary checks never use the operator's Codex account or candidate data.
unset COPILOT_LIVE_SYNTHETIC_CLEANUP COPILOT_LIVE_SYNTHETIC_REVIEW
xcrun swift test --disable-keychain --disable-netrc
xcrun swift build -c release --disable-keychain --disable-netrc
if [ -e .git ]; then git diff --check; fi
