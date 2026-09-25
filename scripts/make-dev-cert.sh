#!/usr/bin/env bash
# Creates a self-signed code-signing identity in the login keychain.
# Signing with a stable identity (instead of ad-hoc "-") keeps AFK's Accessibility
# grant valid across rebuilds; ad-hoc grants are pinned to one build's cdhash.
# Remove later with: security delete-identity -c "AFK Local Dev"
set -euo pipefail

NAME="${1:-AFK Local Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✅ '$NAME' already exists"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/openssl.cnf" <<EOF
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
EOF

# System LibreSSL writes PKCS#12 that `security import` accepts (OpenSSL 3 needs -legacy).
OPENSSL=/usr/bin/openssl
PASS="afk-dev"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
    -out "$tmp/identity.p12" -passout "pass:$PASS"
security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "✅ Created code-signing identity '$NAME'"
