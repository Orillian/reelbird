#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity for local Reelbird builds.
#
# Why: macOS ties the Screen Recording, Camera and Microphone permissions to an
# app's code signature. An ad-hoc signature ("-") changes on every build, so
# macOS forgets the permission each time you rebuild. Signing every build with
# the same certificate keeps the app's designated requirement stable, so the
# permission sticks.
#
# Usage:
#   scripts/dev-signing.sh            create the identity if it is missing, then print the export line
#   scripts/dev-signing.sh --remove   delete the identity again
#
# Then build with it:
#   export RB_SIGN_IDENTITY="Reelbird Local Signing"
#   scripts/build-app.sh
#
# Safe to run more than once: if the identity already exists, it changes nothing.
#
# What it touches: one certificate and one private key in your login keychain
# (or in $RB_KEYCHAIN if set). Nothing else. The certificate is only used to sign
# apps you build yourself on this Mac; it is not trusted for anything else and
# never leaves the machine.
#
# The first time codesign uses the key, macOS asks whether "codesign" may use
# the "Reelbird Local Signing" key. Enter your login password and choose
# "Always Allow" so later builds don't ask again.
set -euo pipefail

NAME="Reelbird Local Signing"
KEYCHAIN="${RB_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
# macOS's own LibreSSL writes PKCS#12 files that `security import` reads.
# Homebrew OpenSSL 3+ defaults to ciphers it can't, so don't use whatever is on PATH.
OPENSSL=/usr/bin/openssl

have_identity() {
  security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1
}

print_next_steps() {
  echo
  echo "Add this to your shell (or run it before scripts/build-app.sh):"
  echo
  echo "  export RB_SIGN_IDENTITY=\"$NAME\""
  echo
}

if [ "${1:-}" = "--remove" ]; then
  if have_identity; then
    # Deletes the certificate and its private key.
    security delete-identity -c "$NAME" "$KEYCHAIN" >/dev/null
    echo "Removed \"$NAME\" from $KEYCHAIN."
  else
    echo "\"$NAME\" is not in $KEYCHAIN. Nothing to remove."
  fi
  exit 0
fi

if [ -n "${1:-}" ]; then
  echo "Unknown option: $1 (use --remove, or no option)" >&2
  exit 64
fi

if have_identity; then
  echo "\"$NAME\" already exists in $KEYCHAIN. Nothing to do."
  print_next_steps
  exit 0
fi

for tool in "$OPENSSL" security; do
  command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 69; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reelbird-signing.XXXXXX")"
chmod 700 "$WORK"
# The private key only exists in this folder until it is imported; always delete it.
trap 'rm -rf "$WORK"' EXIT

# A certificate that codesign accepts: a leaf (not a CA) with the
# digitalSignature key usage and the codeSigning extended key usage.
cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
CNF

echo "Creating a self-signed code-signing certificate \"$NAME\" (valid for 10 years)..."
"$OPENSSL" req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>"$WORK/openssl.log" \
  || { cat "$WORK/openssl.log" >&2; exit 1; }

# PKCS#12 bundle for `security import`. The password only protects this
# temporary file; it is random and never shown or stored.
P12_PASS="$("$OPENSSL" rand -hex 24)"
"$OPENSSL" pkcs12 -export -name "$NAME" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
  -passout "pass:$P12_PASS" 2>"$WORK/openssl.log" \
  || { cat "$WORK/openssl.log" >&2; exit 1; }

# -T lets /usr/bin/codesign use the key; macOS still asks once (see above).
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 \
  -P "$P12_PASS" -T /usr/bin/codesign >/dev/null

if ! have_identity; then
  echo "Import failed: \"$NAME\" is not in $KEYCHAIN." >&2
  exit 1
fi

echo "Done. \"$NAME\" is in $KEYCHAIN."
echo "It shows as \"not trusted\" in Keychain Access. That is expected and fine for local builds."
echo "After the first build signed with it, grant Screen Recording once more; later rebuilds keep it."
print_next_steps
