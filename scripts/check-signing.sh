#!/usr/bin/env bash
# Report what AFK needs for local installs vs stranger-ready DMG distribution.
# Safe / read-only: never prints secrets, never creates certs or notary profiles.
#
# Usage: ./scripts/check-signing.sh
#        make signing-status
set -euo pipefail

EXPECTED_TEAM="${AFK_TEAM_ID:-6FQUWPKXD8}"
NOTARY_PROFILE="${AFK_NOTARY_PROFILE:-AFK-notary}"

echo "AFK signing status"
echo "=================="
echo ""

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -z "$IDENTITIES" ]] || echo "$IDENTITIES" | grep -q "0 valid identities"; then
  echo "Identities: (none)"
else
  echo "Identities:"
  echo "$IDENTITIES" | sed 's/^/  /'
fi
echo ""

DEV_APP="$(
  echo "$IDENTITIES" \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
    | head -1
)"
APPLE_DEV="$(
  echo "$IDENTITIES" \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
    | head -1
)"
LOCAL_DEV=""
if echo "$IDENTITIES" | grep -F '"AFK Local Dev"' >/dev/null; then
  LOCAL_DEV="AFK Local Dev"
fi

# --- Local install path (TCC-stable) ---
echo "Local install (make install)"
if [[ -n "$LOCAL_DEV" ]]; then
  echo "  ✅ AFK Local Dev — stable TCC across rebuilds"
elif [[ -n "$APPLE_DEV" ]]; then
  echo "  ✅ Apple Development — OK on this Mac / team devices"
  echo "     $APPLE_DEV"
else
  echo "  ❌ No stable identity — run: make dev-cert"
  echo "     (or sign into Xcode so Apple Development appears)"
fi
echo ""

# --- Distribution path ---
echo "Distribution (stranger DMG / Gatekeeper)"
if [[ -n "$DEV_APP" ]]; then
  echo "  ✅ Developer ID Application present"
  echo "     $DEV_APP"
  TEAM_FROM_ID="$(echo "$DEV_APP" | sed -n 's/.*(\([^)]*\)).*/\1/p')"
  if [[ -n "$TEAM_FROM_ID" ]]; then
    if [[ "$TEAM_FROM_ID" == "$EXPECTED_TEAM" ]]; then
      echo "  ✅ Team ID matches expected: $EXPECTED_TEAM"
    else
      echo "  ⚠️  Team ID in cert is $TEAM_FROM_ID (docs expect $EXPECTED_TEAM)"
    fi
  fi
else
  echo "  ❌ Developer ID Application — MISSING"
  echo "     Apple Development alone does NOT satisfy Gatekeeper on other Macs."
  echo ""
  echo "     One-time create on this Mac (GUI — cannot be done via SSH/agent Shell):"
  echo "       Preferred — Xcode:"
  echo "         1. Open Xcode → Settings… (⌘,) → Accounts"
  echo "         2. Select Apple ID billyuchenlin@gmail.com"
  echo "         3. Select team Yuchen Lin ($EXPECTED_TEAM) → Manage Certificates…"
  echo "         4. Click + → Developer ID Application"
  echo "         5. Enter Mac password / Touch ID if prompted; wait for cert to appear"
  echo ""
  echo "       Alternate — developer.apple.com:"
  echo "         1. Sign in as billyuchenlin@gmail.com"
  echo "         2. Certificates, Identifiers & Profiles → Certificates → +"
  echo "         3. Developer ID Application → continue"
  echo "         4. Create a CSR in Keychain Access (Certificate Assistant →"
  echo "            Request a Certificate From a Certificate Authority)"
  echo "         5. Upload CSR, download .cer, double-click to install into login keychain"
  echo ""
  echo "     Then re-run: make signing-status && make dmg"
fi
echo ""

# --- Notary ---
echo "Notarization (after Developer ID DMG exists)"
NOTARY="$(/usr/bin/xcrun --find notarytool 2>/dev/null || true)"
if [[ -z "$NOTARY" ]]; then
  echo "  ❌ notarytool not found (need full Xcode)"
else
  echo "  ✅ notarytool: $NOTARY"
fi

# Probe keychain profile without printing credentials. history fails clearly if missing.
if [[ -n "$NOTARY" ]]; then
  if "$NOTARY" history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "  ✅ Keychain profile \"$NOTARY_PROFILE\" works"
  else
    echo "  ❌ Keychain profile \"$NOTARY_PROFILE\" not stored yet"
    echo "     Run locally (prompts; do NOT paste password into chat):"
    echo "       xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "         --apple-id \"billyuchenlin@gmail.com\" \\"
    echo "         --team-id \"$EXPECTED_TEAM\" \\"
    echo "         --password"
    echo "     (omit password value → secure prompt; or use App Store Connect API key)"
  fi
fi
echo ""

# --- Summary ---
echo "Summary"
READY_DMG=0
READY_SHIP=0
[[ -n "$DEV_APP" ]] && READY_DMG=1
if [[ -n "$DEV_APP" && -n "$NOTARY" ]]; then
  if "$NOTARY" history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    READY_SHIP=1
  fi
fi

if [[ "$READY_SHIP" -eq 1 ]]; then
  echo "  ✅ Ready to: make dmg → notarytool submit → stapler staple"
elif [[ "$READY_DMG" -eq 1 ]]; then
  echo "  ➡️  Developer ID OK — make dmg will Hardened-Runtime sign."
  echo "     Still need notary credentials before strangers get a clean open."
else
  echo "  ➡️  Blocked on Developer ID Application (create via Xcode or apple.com above)."
  echo "     make dmg still works for packaging practice (local signature only)."
fi
echo ""
echo "See docs/DISTRIBUTION.md"
