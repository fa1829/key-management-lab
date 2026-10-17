#!/usr/bin/env bash
# Module 02 -- Two-tier PKI whose CA private keys live in the HSM.
#   Root CA (EC P-384, token root-ca)  --signs-->  Issuing CA (RSA 3072, token issuing-ca)
#   Issuing CA  --signs-->  server, client and KMIP certificates
# OpenSSL reaches the HSM through the PKCS#11 provider, using pkcs11: URIs instead of key files.
set -euo pipefail
source "$(dirname "$0")/../config/lab.env"

ROOT_KEY="pkcs11:token=root-ca;object=root-ca-key;type=private?pin-value=$USER_PIN"
ISS_KEY="pkcs11:token=issuing-ca;object=issuing-ca-key;type=private?pin-value=$USER_PIN"

mkdir -p "$PKI_DIR"/{root,issuing,certs,keys,csr}
chmod 700 "$PKI_DIR/keys"

# --- OpenSSL 3 config that loads the default provider + the PKCS#11 provider ---
cat > "$OPENSSL_CONF" <<EOF
openssl_conf = openssl_init
[openssl_init]
providers = provider_sect
[provider_sect]
default = default_sect
pkcs11 = pkcs11_sect
[default_sect]
activate = 1
[pkcs11_sect]
module = $PKCS11_PROVIDER
pkcs11-module-path = $PKCS11_MODULE
activate = 1
EOF

# --- CA database and policy for 'openssl ca' (shared by both CAs) ---
ca_conf() {  # $1 = ca dir, $2 = default_days, $3 = crl days
cat > "$1/ca.cnf" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir               = $1
database          = \$dir/index.txt
new_certs_dir     = \$dir/newcerts
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
default_md        = sha256
default_days      = $2
default_crl_days  = $3
policy            = policy_any
unique_subject    = no
copy_extensions   = copy
[ policy_any ]
commonName        = supplied
organizationName  = optional
countryName       = optional
[ v3_issuing_ca ]
basicConstraints       = critical, CA:true, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
crlDistributionPoints  = URI:http://pki.lab.local/root.crl
[ server_cert ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid
crlDistributionPoints  = URI:http://pki.lab.local/issuing.crl
[ client_cert ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = clientAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid
crlDistributionPoints  = URI:http://pki.lab.local/issuing.crl
EOF
mkdir -p "$1/newcerts"; touch "$1/index.txt"
[ -f "$1/serial" ] || openssl rand -hex 16 > "$1/serial"
[ -f "$1/crlnumber" ] || echo 1000 > "$1/crlnumber"
}
ca_conf "$PKI_DIR/root" 1825 30
ca_conf "$PKI_DIR/issuing" 90 7

# --- 1. Self-signed root certificate, signed by the key inside token root-ca ---
if [ ! -f "$PKI_DIR/root/root-ca.crt" ]; then
  openssl req -new -x509 -days 3650 -sha384 -key "$ROOT_KEY" \
    -subj "/C=CA/O=Key Management Lab/CN=Lab Root CA" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$PKI_DIR/root/root-ca.crt"
  echo "root CA certificate created (key stayed in token root-ca)"
fi

# --- 2. Issuing CA: CSR signed by the issuing key, certificate signed by the root key ---
if [ ! -f "$PKI_DIR/issuing/issuing-ca.crt" ]; then
  openssl req -new -key "$ISS_KEY" -subj "/C=CA/O=Key Management Lab/CN=Lab Issuing CA 1" \
    -out "$PKI_DIR/csr/issuing-ca.csr"
  openssl ca -batch -config "$PKI_DIR/root/ca.cnf" -extensions v3_issuing_ca -days 1825 \
    -cert "$PKI_DIR/root/root-ca.crt" -keyfile "$ROOT_KEY" \
    -in "$PKI_DIR/csr/issuing-ca.csr" -out "$PKI_DIR/issuing/issuing-ca.crt" -notext 2>/dev/null
  echo "issuing CA certificate created (signed inside token root-ca)"
fi
cat "$PKI_DIR/issuing/issuing-ca.crt" "$PKI_DIR/root/root-ca.crt" > "$PKI_DIR/chain.pem"

# --- 3. End-entity certificates (application keys on disk, as most servers have) ---
"$(dirname "$0")/02_pki_issue.sh" server  web.lab.local     90
"$(dirname "$0")/02_pki_issue.sh" server  kmip-server       90
"$(dirname "$0")/02_pki_issue.sh" client  kmip-client       90
"$(dirname "$0")/02_pki_issue.sh" server  legacy-api.lab.local 5    # short-lived: will trip the expiry alert
"$(dirname "$0")/02_pki_issue.sh" client  contractor-laptop 30     # will be revoked in 02_pki_revoke.sh

echo
echo "==> Verify each certificate against the chain"
for c in "$PKI_DIR"/certs/*.crt; do
  openssl verify -CAfile "$PKI_DIR/root/root-ca.crt" -untrusted "$PKI_DIR/issuing/issuing-ca.crt" "$c" | sed 's|.*/||'
done
