#!/usr/bin/env bash
# Module 01a -- Create three HSM tokens (think: three Luna partitions).
#   root-ca    : offline root CA key, used only to sign the issuing CA
#   issuing-ca : online issuing CA key, signs server and client certificates
#   app-keys   : application key-encryption keys (KEKs) for envelope encryption
set -euo pipefail
source "$(dirname "$0")/../config/lab.env"

mkdir -p "$RUN_DIR/tokens"
cat > "$SOFTHSM2_CONF" <<EOF
directories.tokendir = $RUN_DIR/tokens
objectstore.backend = file
log.level = INFO
slots.removable = false
EOF

for label in root-ca issuing-ca app-keys; do
  if softhsm2-util --show-slots | grep -q "Label:.*$label"; then
    echo "token '$label' already exists, skipping"
  else
    softhsm2-util --init-token --free --label "$label" --so-pin "$SO_PIN" --pin "$USER_PIN" >/dev/null
    echo "initialised token '$label'"
  fi
done

echo
echo "==> Slots and tokens seen through the PKCS#11 interface"
pkcs11-tool --module "$PKCS11_MODULE" --list-token-slots | grep -E "Slot|token label"
