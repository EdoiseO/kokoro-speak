#!/bin/zsh
# Creates a self-signed code-signing certificate named "Kokoro Speak Local Signing"
# in your login keychain, if it isn't there already.
#
# Signing every build with the same certificate keeps the app's identity stable,
# so macOS keeps its Accessibility permission across updates. The certificate
# never leaves this Mac, and only codesign is allowed to use its key.
# Remove it at any time with: security delete-identity -c "Kokoro Speak Local Signing"
set -euo pipefail

NAME="Kokoro Speak Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "    signing certificate already exists"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.conf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
# A random one-time password protects the bundle only while it's imported.
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" -out "$WORK/identity.p12" >/dev/null 2>&1
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "    created \"$NAME\" in your login keychain"
