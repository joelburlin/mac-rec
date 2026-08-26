#!/bin/bash
# One-time: create a self-signed code-signing identity in a dedicated keychain
# (non-interactive). TCC then pins the CERTIFICATE, not the binary hash, so
# Screen Recording / Microphone grants survive every rebuild.
set -euo pipefail

KC="$HOME/.config/mac-rec/signing.keychain-db"
PASS="mac-rec-local-signing"
NAME="mac-rec-signing"

if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
    echo "signing identity already present: $KC"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# -legacy: openssl 3 default PKCS12 crypto is unreadable by macOS `security import`
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$PASS" 2>/dev/null \
    || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -passout "pass:$PASS" 2>/dev/null

mkdir -p "$(dirname "$KC")"
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"   # no auto-lock
security unlock-keychain -p "$PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign
# Pre-authorize codesign so signing never pops a keychain dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null

echo "created signing identity \"$NAME\" in $KC"
