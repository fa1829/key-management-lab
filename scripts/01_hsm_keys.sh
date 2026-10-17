#!/usr/bin/env bash
# Module 01b -- Generate keys INSIDE the HSM tokens and prove the private keys cannot leave.
set -euo pipefail
source "$(dirname "$0")/../config/lab.env"
P11="pkcs11-tool --module $PKCS11_MODULE --pin $USER_PIN"

has_obj() { $P11 --token-label "$1" --list-objects 2>/dev/null | grep -q "label:.*$2"; }

echo "==> Root CA key pair: EC P-384, generated in token 'root-ca'"
has_obj root-ca root-ca-key || $P11 --token-label root-ca --keypairgen \
  --key-type EC:secp384r1 --label root-ca-key --id 01 --usage-sign --sensitive >/dev/null 2>&1

echo "==> Issuing CA key pair: RSA 3072, generated in token 'issuing-ca'"
has_obj issuing-ca issuing-ca-key || $P11 --token-label issuing-ca --keypairgen \
  --key-type rsa:3072 --label issuing-ca-key --id 02 --usage-sign --sensitive >/dev/null 2>&1

echo "==> Key-encryption key (KEK): AES-256, generated in token 'app-keys'"
has_obj app-keys kek-v1 || $P11 --token-label app-keys --keygen \
  --key-type AES:32 --label kek-v1 --id 10 --sensitive \
  --usage-wrap --usage-decrypt >/dev/null 2>&1

echo
echo "==> Objects in 'root-ca' (look at the Access line: sensitive, never extractable, local)"
$P11 --token-label root-ca --list-objects 2>/dev/null | sed 's/^/    /'

echo
echo "==> Sign a message with the root CA key inside the HSM, verify with the public key"
WORK="$RUN_DIR/hsm-demo"; mkdir -p "$WORK"
echo "release-manifest v1.4.2 sha256=..." > "$WORK/message.txt"
# SoftHSM implements raw ECDSA, so we hash on the host and the HSM signs the digest.
# (Luna also offers ECDSA-SHA256 in one step; the resulting signature is the same.)
openssl dgst -sha256 -binary "$WORK/message.txt" > "$WORK/message.sha256"
$P11 --token-label root-ca --sign --id 01 --mechanism ECDSA \
  --input-file "$WORK/message.sha256" --output-file "$WORK/message.sig" --signature-format openssl 2>/dev/null
$P11 --token-label root-ca --read-object --type pubkey --id 01 --output-file "$WORK/root-ca-pub.der" 2>/dev/null
openssl pkey -pubin -inform DER -in "$WORK/root-ca-pub.der" -out "$WORK/root-ca-pub.pem"
openssl dgst -sha256 -verify "$WORK/root-ca-pub.pem" -signature "$WORK/message.sig" "$WORK/message.txt"

echo
echo "==> Non-extractability is proven in Python next (reading CKA_VALUE must be refused):"
echo "    .venv/bin/python python/pkcs11_envelope.py"
