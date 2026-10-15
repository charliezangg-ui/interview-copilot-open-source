#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-toolchain.sh
APP="${COPILOT_APP_OUTPUT:-dist/InterviewCopilot.app}"
case "$APP" in *.app) ;; *) echo "COPILOT_APP_OUTPUT must end with .app" >&2; exit 1 ;; esac
mkdir -p "$(dirname "$APP")"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
if [ -L "$APP" ]; then echo "Refusing to replace an app symlink." >&2; exit 1; fi
if [ -e "$APP" ]; then
  APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$APP_ID" != "local.interview-copilot.demo" ]; then echo "Refusing to replace a different application." >&2; exit 1; fi
fi
assert_app_closed() {
  if /bin/ps -axo comm= | /usr/bin/grep -Fx "$APP/Contents/MacOS/InterviewCopilot" >/dev/null; then
    echo "请先保存并退出 InterviewCopilot，再重新打包；不会覆盖正在运行的应用。" >&2
    exit 1
  fi
}
assert_app_closed
IDENTITY="${COPILOT_SIGNING_IDENTITY:-InterviewCopilot Local Development}"
if [ "$IDENTITY" = "-" ]; then
  echo "拒绝 ad-hoc 更新：每次更新会改变录音授权身份。请配置固定的代码签名证书。" >&2
  exit 1
fi
# Fail before building or touching the installed app if the stable identity is absent.
IDENTITIES="$(security find-identity -v -p codesigning)"
if ! printf '%s\n' "$IDENTITIES" | /usr/bin/grep -F -- "$IDENTITY" >/dev/null; then
  echo "找不到有效签名证书：$IDENTITY。现有应用未修改。参见 README 的本机开发签名步骤。" >&2
  exit 1
fi
xcrun swift build -c release --disable-keychain --disable-netrc
BIN_DIR="$(xcrun swift build -c release --show-bin-path --disable-keychain --disable-netrc)"
STAGING="$(mktemp -d "$(dirname "$APP")/.build-app.XXXXXX")"
cleanup() {
  # Roll back if replacing the app was interrupted after moving its previous version.
  if [ ! -d "$APP" ] && [ -d "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$APP"; fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
NEXT="$STAGING/InterviewCopilot.app"
mkdir -p "$NEXT/Contents/MacOS" "$NEXT/Contents/Resources/Licenses"
cp "$BIN_DIR/InterviewCopilot" "$NEXT/Contents/MacOS/InterviewCopilot"
cp Resources/Info.plist "$NEXT/Contents/Info.plist"
cp Sources/LocalASR/model-manifest.json "$NEXT/Contents/Resources/"
cp Resources/THIRD_PARTY_NOTICES.md "$NEXT/Contents/Resources/"
install -m 644 Resources/Licenses/*.txt "$NEXT/Contents/Resources/Licenses/"
if [ -f LICENSE ]; then install -m 644 LICENSE "$NEXT/Contents/Resources/Licenses/InterviewCopilot.txt"; fi
if [ "${COPILOT_DISTRIBUTION:-0}" = "1" ]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements Resources/Distribution.entitlements "$NEXT"
  if ! codesign -dvv "$NEXT" 2>&1 | /usr/bin/grep -q '^Authority=Developer ID Application:'; then
    echo "Public distribution requires a Developer ID Application identity." >&2; exit 1
  fi
else
  codesign --force --sign "$IDENTITY" "$NEXT"
fi
codesign --verify --deep --strict "$NEXT"
if [ -d "$APP" ]; then
  OLD_REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
  if [ -z "$OLD_REQUIREMENT" ] || ! codesign --verify --strict -R="$OLD_REQUIREMENT" "$NEXT" 2>/dev/null; then
    if [ "${COPILOT_ALLOW_SIGNING_MIGRATION:-0}" != "1" ]; then
      echo "签名身份发生变化，已保留旧版。首次证书迁移需显式设置 COPILOT_ALLOW_SIGNING_MIGRATION=1，并重新授权。" >&2
      exit 1
    fi
    echo "正在执行已明确选择的签名迁移；本次需重新授权。" >&2
  fi
fi
assert_app_closed
if [ -d "$APP" ]; then mv "$APP" "$STAGING/previous.app"; fi
mv "$NEXT" "$APP"
echo "Built with stable identity: $APP"
