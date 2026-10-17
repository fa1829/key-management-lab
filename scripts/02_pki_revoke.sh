#!/usr/bin/env bash
# Module 02b -- Revoke a certificate and publish a CRL signed inside the HSM.
# Usage: 02_pki_revoke.sh [common-name] [reason]   (defaults: contractor-laptop keyCompromise)
set -euo pipefail
source "$(dirname "$0")/../config/lab.env"
CN="${1:-contractor-laptop}"; REASON="${2:-keyCompromise}"
ISS_KEY="pkcs11:token=issuing-ca;object=issuing-ca-key;type=private?pin-value=$USER_PIN"
CRT="$PKI_DIR/certs/$CN.crt"; CRL="$PKI_DIR/issuing/issuing.crl"
CHAIN_ARGS=(-CAfile "$PKI_DIR/root/root-ca.crt" -untrusted "$PKI_DIR/issuing/issuing-ca.crt")

echo "==> Before revocation, with CRL checking:"
openssl ca -gencrl -config "$PKI_DIR/issuing/ca.cnf" -cert "$PKI_DIR/issuing/issuing-ca.crt" \
  -keyfile "$ISS_KEY" -out "$CRL" 2>/dev/null
openssl verify "${CHAIN_ARGS[@]}" -crl_check -CRLfile "$CRL" "$CRT" | sed 's|.*/||' || true

echo "==> Revoking CN=$CN (reason: $REASON)"
openssl ca -config "$PKI_DIR/issuing/ca.cnf" -cert "$PKI_DIR/issuing/issuing-ca.crt" \
  -keyfile "$ISS_KEY" -revoke "$CRT" -crl_reason "$REASON" 2>/dev/null || echo "   (already revoked)"

echo "==> Publishing a new CRL, signed by the issuing CA key inside the HSM"
openssl ca -gencrl -config "$PKI_DIR/issuing/ca.cnf" -cert "$PKI_DIR/issuing/issuing-ca.crt" \
  -keyfile "$ISS_KEY" -out "$CRL" 2>/dev/null
openssl crl -in "$CRL" -noout -text | grep -E "Last Update|Next Update|Serial Number|Compromise|Superseded|Cessation" | sed 's/^ */   /'

echo "==> After revocation, the same check fails:"
openssl verify "${CHAIN_ARGS[@]}" -crl_check -CRLfile "$CRL" "$CRT" 2>&1 | sed 's|.*/||' || true
