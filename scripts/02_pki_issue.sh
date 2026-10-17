#!/usr/bin/env bash
# Issue (or re-issue) one end-entity certificate from the HSM-backed issuing CA.
# Usage: 02_pki_issue.sh <server|client> <common-name> <days> [--rekey]
#   --rekey generates a new key pair (key rotation); without it an existing key is reused.
set -euo pipefail
source "$(dirname "$0")/../config/lab.env"
TYPE="$1"; CN="$2"; DAYS="$3"; REKEY="${4:-}"
ISS_KEY="pkcs11:token=issuing-ca;object=issuing-ca-key;type=private?pin-value=$USER_PIN"
KEY="$PKI_DIR/keys/$CN.key"; CSR="$PKI_DIR/csr/$CN.csr"; CRT="$PKI_DIR/certs/$CN.crt"

if [ ! -f "$KEY" ] || [ "$REKEY" = "--rekey" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY" 2>/dev/null
  chmod 600 "$KEY"
fi

SAN="DNS:$CN"; [ "$CN" = "kmip-server" ] && SAN="DNS:kmip-server,DNS:localhost,IP:127.0.0.1"
openssl req -new -key "$KEY" -subj "/O=Key Management Lab/CN=$CN" \
  $( [ "$TYPE" = server ] && echo "-addext subjectAltName=$SAN" ) -out "$CSR"

openssl ca -batch -config "$PKI_DIR/issuing/ca.cnf" -extensions "${TYPE}_cert" -days "$DAYS" \
  -cert "$PKI_DIR/issuing/issuing-ca.crt" -keyfile "$ISS_KEY" \
  -in "$CSR" -out "$CRT" -notext 2>/dev/null

echo "issued $TYPE certificate CN=$CN, valid $DAYS days, serial $(openssl x509 -in "$CRT" -noout -serial | cut -d= -f2)"
