#!/bin/bash
# Creates a free, self-signed code-signing certificate ("MacEverything Local Signing") and
# trusts it for code signing, so make-app.sh can sign with a stable identity and Full Disk
# Access survives rebuilds. Run once per Mac. Not for distributing to other Macs: use an
# Apple Developer ID for that.
#
#   ./scripts/create-signing-cert.sh        your login keychain; macOS asks for your password
#   ./scripts/create-signing-cert.sh --ci   a throwaway keychain, trusted with sudo (CI only)
set -euo pipefail
NAME="MacEverything Local Signing"
CI_MODE=0
[ "${1:-}" = "--ci" ] && CI_MODE=1

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists and is trusted for code signing."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The system LibreSSL writes PKCS#12 files that the macOS keychain can import
# (OpenSSL 3, as installed by Homebrew, needs extra flags for that).
OPENSSL=/usr/bin/openssl
cat > "$WORK/cert.cnf" <<CNF
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
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout pass:mev

if [ "$CI_MODE" = 1 ]; then
  KEYCHAIN="$HOME/Library/Keychains/mev-ci.keychain-db"
  security create-keychain -p mev "$KEYCHAIN" 2>/dev/null || true
  security unlock-keychain -p mev "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  security import "$WORK/id.p12" -k "$KEYCHAIN" -P mev -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k mev "$KEYCHAIN" >/dev/null
  sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$WORK/cert.pem"
else
  KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
  security import "$WORK/id.p12" -k "$KEYCHAIN" -P mev -T /usr/bin/codesign
  echo "macOS will now ask for your password to trust the certificate for code signing."
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
fi

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Created \"$NAME\". Rebuild with ./scripts/install.sh, then grant Full Disk Access one"
  echo "last time; later rebuilds keep it. (The first signing may ask to use the key: choose"
  echo "Always Allow.)"
else
  echo "The certificate was imported but is not trusted for code signing." >&2
  exit 1
fi
