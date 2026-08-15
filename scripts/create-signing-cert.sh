#!/bin/bash
#
# Create a per-machine self-signed code-signing certificate for Verbalise.
#
# Why: macOS ties Accessibility (and other TCC) grants to the app's code
# signature. Unsigned builds get a fresh ad-hoc signature every time, so
# every reinstall voids the permission. Signing each build with one stable
# local certificate makes rebuilds look like the same app, and permissions
# survive updates.
#
# The certificate lives only in this Mac's login Keychain. Run once per
# machine (idempotent — safe to re-run). macOS will ask for your login
# password when trusting the certificate; that's expected.
set -euo pipefail

IDENTITY="Verbalise Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Verbalise Dev
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
CONF

echo "==> Generating certificate..."
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null

# Legacy PBE algorithms: OpenSSL 3.x defaults to AES/PBKDF2, which macOS's
# `security import` can't parse ("MAC verification failed").
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:verbalise \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

echo "==> Importing into login Keychain..."
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P verbalise -T /usr/bin/codesign

echo "==> Trusting for code signing (macOS will ask for your login password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "Done. Builds will now be signed as '$IDENTITY'."
echo "If the first build shows a Keychain prompt, click 'Always Allow'."
