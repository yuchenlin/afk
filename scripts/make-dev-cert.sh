#!/usr/bin/env bash
# Creates a self-signed code-signing identity in the login keychain.
# Signing with a stable identity (instead of ad-hoc "-") keeps AFK's Accessibility
# and Microphone grants valid across rebuilds; ad-hoc grants are pinned to one
# build's CDHash and disappear on every `make install`.
#
# Remove later with: security delete-identity -c "AFK Local Dev"
set -euo pipefail

NAME="${1:-AFK Local Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$NAME\"" >/dev/null; then
    echo "✅ '$NAME' is already a valid code-signing identity"
    exit 0
fi

# Certificate may exist but be untrusted (CSSMERR_TP_NOT_TRUSTED) — recreate cleanly.
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "⚠️  '$NAME' exists but isn't trusted for Code Signing — removing so we can recreate."
    security delete-identity -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 || true
    security delete-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 || true
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# System LibreSSL writes PKCS#12 that `security import` accepts (OpenSSL 3 needs -legacy).
OPENSSL=/usr/bin/openssl
PASS="afk-dev"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
    -out "$tmp/identity.p12" -passout "pass:$PASS"
security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

# Allow codesign to use the key without a GUI prompt on each build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "✅ Created code-signing identity '$NAME'"
echo ""
echo "One more step (needs your Mac password once): trust it for Code Signing."
echo "  1. Open Keychain Access → login → Certificates → '$NAME'"
echo "  2. Double-click → Trust → Code Signing → 'Always Trust' → close (enter password)"
echo "  Or run (admin password prompt):"
echo "     security add-trusted-cert -d -r unspecified -p codeSign \"$tmp/cert.pem\""
echo "     # (re-run make-dev-cert after trusting if you used the GUI path)"
# Leave cert.pem copy the user can trust without re-export:
cp "$tmp/cert.pem" "$HOME/Library/Application Support/AFK/afk-local-dev.cer" 2>/dev/null \
  || (mkdir -p "$HOME/Library/Application Support/AFK" && cp "$tmp/cert.pem" "$HOME/Library/Application Support/AFK/afk-local-dev.cer")
# Keep trap from deleting before user might need it — already copied.
echo "     Certificate also saved at: ~/Library/Application Support/AFK/afk-local-dev.cer"
echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$NAME\"" >/dev/null; then
    echo "✅ '$NAME' is valid — make install will use it."
else
    echo "⚠️  Until trusted, 'make install' will use an Apple Development identity if one exists,"
    echo "   or refuse to install (ad-hoc would keep breaking permissions)."
fi
