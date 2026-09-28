#!/usr/bin/env bash
# Build a drag-to-Applications DMG containing AFK.app.
#
# Output: dist/AFK-<version>.dmg
#
# Signing (optional re-sign for packaging):
#   - If a "Developer ID Application: …" identity exists, re-sign AFK.app with it
#     (Hardened Runtime) before packaging — required path for stranger installs.
#   - Else keep whatever `make build` signed with (Apple Development / Local Dev /
#     ad-hoc). That is fine for packaging practice on your Mac; Gatekeeper will
#     still block other users until you create a Developer ID cert + notarize.
#   - Xcode Apple ID login alone does NOT create Developer ID Application.
#   - This script never calls notarytool (needs a stored keychain profile).
#   See docs/DISTRIBUTION.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_BUNDLE="${APP_BUNDLE:-AFK.app}"
DIST_DIR="${DIST_DIR:-dist}"
VOLUME_NAME="${VOLUME_NAME:-AFK}"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "❌ $APP_BUNDLE missing — run \`make build\` (or \`make dmg\`) first." >&2
  exit 1
fi

# Prefer Developer ID Application when present (distribution). Do not invent one.
DEV_ID_IDENTITY="$(
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -1
)"

# iCloud key-value storage is a restricted entitlement: macOS refuses to launch an app that
# claims it without an embedded provisioning profile matching the signing certificate.
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-Supporting/AFK.provisionprofile}"

if [[ -n "$DEV_ID_IDENTITY" ]]; then
  echo "🔏 Re-signing $APP_BUNDLE with $DEV_ID_IDENTITY (Hardened Runtime)…"
  if [[ -f "$PROVISIONING_PROFILE" ]]; then
    cp "$PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    ENTITLEMENTS="${ENTITLEMENTS:-Supporting/AFK.entitlements}"
    echo "   Embedded $PROVISIONING_PROFILE (iCloud vocabulary sync on)"
  else
    rm -f "$APP_BUNDLE/Contents/embedded.provisionprofile"
    ENTITLEMENTS="${ENTITLEMENTS:-Supporting/AFK.local.entitlements}"
    echo "⚠️  No $PROVISIONING_PROFILE: signing without iCloud so the app still launches."
    echo "   Download the Developer ID profile for xyz.yuchenlin.afk (see docs/DISTRIBUTION.md)."
  fi
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$DEV_ID_IDENTITY" "$APP_BUNDLE"
  # Fail before packaging if the signature doesn't verify.
  if ! codesign --verify --strict "$APP_BUNDLE" 2>/dev/null; then
    echo "❌ $APP_BUNDLE failed codesign verification" >&2
    exit 1
  fi
  SIGN_KIND="Developer ID"
else
  echo "ℹ️  No \"Developer ID Application\" identity in the keychain."
  echo "   Packaging with the existing signature from \`make build\`."
  echo "   Xcode → Settings → Accounts login alone is not enough for stranger installs:"
  echo "   create a Developer ID Application certificate at developer.apple.com"
  echo "   (Certificates → + → Developer ID Application) or via Xcode account"
  echo "   Manage Certificates, then re-run \`make dmg\`."
  SIGN_KIND="local-only"
fi

VERSION="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || echo "0.0.0"
)"
DMG_NAME="AFK-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/afk-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

echo "📦 Staging $APP_BUNDLE → $DMG_PATH"
mkdir -p "$STAGE" "$DIST_DIR"
ditto "$APP_BUNDLE" "$STAGE/$APP_BUNDLE"
ln -s /Applications "$STAGE/Applications"

if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
  hdiutil detach "/Volumes/$VOLUME_NAME" -quiet 2>/dev/null || true
fi

rm -f "$DMG_PATH" "${DMG_PATH%.dmg}.tmp.dmg"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDRW \
  "${DMG_PATH%.dmg}.tmp.dmg"

hdiutil convert \
  "${DMG_PATH%.dmg}.tmp.dmg" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

rm -f "${DMG_PATH%.dmg}.tmp.dmg"

echo ""
echo "✅ Wrote $DMG_PATH ($(du -h "$DMG_PATH" | awk '{print $1}'))  [signing: $SIGN_KIND]"
echo "   Signature on packaged app:"
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 \
  | grep -E '^(Identifier|Authority|TeamIdentifier|Signature|Flags|Runtime)=' \
  || echo "   (unsigned / unknown)"
echo "   Entitlements:"
codesign -d --entitlements - "$APP_BUNDLE" 2>&1 \
  | grep -v '^Executable=' \
  || echo "   (none)"
echo ""
if [[ "$SIGN_KIND" != "Developer ID" ]]; then
  echo "⚠️  Gatekeeper: this DMG will NOT open cleanly on other Macs."
  echo "   Need Developer ID Application + notarization (docs/DISTRIBUTION.md)."
else
  echo "➡️  Next (not run automatically): store notary credentials once, then submit:"
  echo "   xcrun notarytool store-credentials AFK-notary   # interactive; Apple ID or API key"
  echo "   xcrun notarytool submit \"$DMG_PATH\" --keychain-profile AFK-notary --wait"
  echo "   xcrun stapler staple \"$DMG_PATH\""
  echo "   See docs/DISTRIBUTION.md — do not paste passwords into chat."
fi
