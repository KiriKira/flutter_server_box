#!/usr/bin/env bash
# Sign only with the durable identity and verify the repository's public pin.
set -euo pipefail
unsigned="${1:?unsigned APK required}"
output="${2:?output APK required}"
: "${KIRIBOX_KEYSTORE_BASE64:?Persistent signing key is not configured}"
: "${KIRIBOX_KEYSTORE_PASSWORD:?Missing store password}"
: "${KIRIBOX_KEY_ALIAS:?Missing alias}"
: "${KIRIBOX_KEY_PASSWORD:?Missing key password}"
: "${APKSIGNER:?apksigner path is required}"
signing_dir="$(mktemp -d)"
trap 'rm -rf -- "$signing_dir"' EXIT
chmod 700 "$signing_dir"
umask 077
printf '%s' "$KIRIBOX_KEYSTORE_BASE64" | base64 --decode > "$signing_dir/key.p12"
mkdir -p "$(dirname "$output")"
"$APKSIGNER" sign --ks "$signing_dir/key.p12" \
  --ks-key-alias "$KIRIBOX_KEY_ALIAS" \
  --ks-pass env:KIRIBOX_KEYSTORE_PASSWORD --key-pass env:KIRIBOX_KEY_PASSWORD \
  --alignment-preserved --v1-signing-enabled false --v2-signing-enabled true \
  --v3-signing-enabled false --v4-signing-enabled false --out "$output" "$unsigned"
"$APKSIGNER" verify --verbose --print-certs "$output" > "$signing_dir/certificate.txt"
actual="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' "$signing_dir/certificate.txt" | head -1)"
expected="$(tr -d '[:space:]' < android/kiribox-signing-sha256.txt)"
if [[ "$actual" != "$expected" ]]; then
  rm -f -- "$output"
  echo '::error::Signing certificate differs from the committed KiriBox identity'
  exit 1
fi
cat "$signing_dir/certificate.txt"
chmod 644 "$output"
