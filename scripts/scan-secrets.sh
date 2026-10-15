#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Pin the scanner binary and its upstream release checksum. No credentials needed.
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM=darwin_arm64; DIGEST=90d13686937ac7429b97a3acbf1e1d0ce90d92ae2d0cf46a690bd8ae5230bea0 ;;
  Darwin-x86_64) PLATFORM=darwin_x64; DIGEST=bc3c46f8039ba716ba8461fa6745c9d1cfb90ca2f5f881d8d0cf66b7ba7b742c ;;
  Linux-x86_64) PLATFORM=linux_x64; DIGEST=fa0500f6b7e41d28791ebc680f5dd9899cd42b58629218a5f041efa899151a8e ;;
  Linux-aarch64) PLATFORM=linux_arm64; DIGEST=574a6d52573c61173add7ddb5e3cc68c0e82cb0735818a1eeb9a0a2de1643fbc ;;
  *) echo "Unsupported scanner platform" >&2; exit 1 ;;
esac
SCAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/interview-copilot-scan.XXXXXX")"
trap 'rm -rf "$SCAN_DIR"' EXIT
curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 120 \
  "https://github.com/gitleaks/gitleaks/releases/download/v8.24.2/gitleaks_8.24.2_${PLATFORM}.tar.gz" -o "$SCAN_DIR/scanner.tar.gz"
python3 - "$SCAN_DIR/scanner.tar.gz" "$DIGEST" <<'PY'
import hashlib, pathlib, sys
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    raise SystemExit('Scanner checksum mismatch')
PY
tar -xzf "$SCAN_DIR/scanner.tar.gz" -C "$SCAN_DIR" gitleaks
if [ -e .git ]; then "$SCAN_DIR/gitleaks" git --redact --no-banner --log-opts='--all' .; fi
# Only export reviewed source; do not scan private-data, local interviews or build output.
python3 scripts/export-source.py
mkdir "$SCAN_DIR/source"
VERSION="$(python3 -c 'import plistlib; print(plistlib.load(open("Resources/Info.plist", "rb"))["CFBundleShortVersionString"])')"
tar -xzf "dist/source/InterviewCopilot-${VERSION}-source.tar.gz" -C "$SCAN_DIR/source"
"$SCAN_DIR/gitleaks" dir --redact --no-banner "$SCAN_DIR/source"
