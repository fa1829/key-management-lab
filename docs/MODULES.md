# Module walkthrough

Each module below says what it does, what to look for in the output, how to inspect the result
yourself, and a few things to try. The *things to try* are where most of the learning happens, and
they map closely to interview questions.

Before using the inspection commands, load the lab variables once per terminal:

```bash
cd ~/projects/key-management-lab
source config/lab.env      # defines $PKCS11_MODULE, $USER_PIN, $PKI_DIR, ...
```

---

## Module 01a: HSM tokens and keys (`make hsm`)

**Goal:** create keys *inside* an HSM and use them without ever seeing them.

**What happens**

1. `01_hsm_init.sh` writes `run/softhsm2.conf` and creates three tokens, mirroring how a bank
   separates keys into Luna partitions by purpose:

   | Token | Holds | Why separate |
   | --- | --- | --- |
   | `root-ca` | EC P-384 root CA key | used a few times a year; in production, offline |
   | `issuing-ca` | RSA 3072 issuing CA key | used daily to sign certificates |
   | `app-keys` | AES-256 key-encryption key (KEK) | protects application data keys |

2. `01_hsm_keys.sh` generates the keys with `pkcs11-tool --keypairgen` / `--keygen --sensitive`,
   lists them, signs a message with the root key **inside** the token, exports only the **public**
   key and verifies the signature with OpenSSL.

**What to look for**

```text
Private Key Object; EC
  label:      root-ca-key
  Access:     sensitive, always sensitive, never extractable, local
...
Verified OK
```

`local` means the key was generated in the token, not imported. `never extractable` means no
operation can ever export it, even encrypted.

**Inspect it yourself**

```bash
softhsm2-util --show-slots
pkcs11-tool --module $PKCS11_MODULE --token-label issuing-ca --login --pin $USER_PIN --list-objects
pkcs11-tool --module $PKCS11_MODULE --token-label app-keys -M        # mechanisms the token supports
```

**Things to try**

- Log in with a wrong PIN: `--pin 000000` gives `CKR_PIN_INCORRECT`. On a Luna HSM, repeated
  failures lock the partition; find out how many attempts your token allows.
- Generate a key **without** `--sensitive` and compare its `Access:` line with `kek-v1`'s.
- Explain why the script hashes with OpenSSL and asks the HSM for raw `ECDSA` (SoftHSM has no
  combined `ECDSA-SHA256` mechanism; Luna does).

## Module 01b: envelope encryption (`make envelope`)

**Goal:** the pattern every KMS-backed application uses: data keys (DEKs) protected by a
key-encryption key (KEK) that never leaves the HSM.

**What happens** (`python/pkcs11_envelope.py`)

| Step | Operation | PKCS#11 call behind it |
| --- | --- | --- |
| 1 | Find the KEK by label | `C_FindObjects` |
| 2 | Try to read the KEK's value | `C_GetAttributeValue(CKA_VALUE)` refused |
| 3 | Generate a session DEK and encrypt a record (AES-CBC) | `C_GenerateKey`, `C_Encrypt` |
| 4 | Wrap the DEK under the KEK (RFC 5649) | `C_WrapKey` with `CKM_AES_KEY_WRAP_PAD` |
| 5 | Unwrap inside the HSM and decrypt | `C_UnwrapKey`, `C_Decrypt` |
| 6 | Try to read the unwrapped DEK | refused: it was unwrapped as sensitive |

**What to look for**

```text
[2] Reading the KEK's value -> CKR_ATTRIBUTE_SENSITIVE (refused by the HSM, as designed)
[4] DEK wrapped by KEK -> 40 bytes; store this next to the ciphertext
[5] Unwrapped the DEK inside the HSM and decrypted the record: round trip OK
```

**Things to try**

- Flip one byte of `wrapped_dek` before unwrapping; AES key wrap has a built-in integrity check, so
  the HSM rejects it. Why is that property important for stored keys?
- Explain why rotating the KEK only requires **re-wrapping** each DEK, not re-encrypting the data.

## Module 02a: HSM-backed PKI (`make pki`)

**Goal:** a two-tier certificate authority whose private keys stay in the HSM.

**What happens** (`02_pki_build.sh`)

1. Writes `run/openssl-pkcs11.cnf`, which loads OpenSSL 3's **PKCS#11 provider** pointed at SoftHSM.
2. Creates the **root CA** certificate with
   `openssl req -x509 -key "pkcs11:token=root-ca;object=root-ca-key;type=private"`. The key is a
   URI, not a file: OpenSSL asks the token to sign.
3. Creates the **issuing CA**: a CSR signed by the issuing key, certified by the root with
   `openssl ca -keyfile "pkcs11:..."`; `pathlen:0` stops it from creating further CAs.
4. Issues five end-entity certificates with `02_pki_issue.sh`: two servers, the KMIP server and
   client (used by module 03), a 5-day certificate that will trip the expiry alert, and a laptop
   certificate that module 02b revokes.
5. Verifies every certificate against the chain.

**Inspect it yourself**

```bash
openssl x509 -in $PKI_DIR/certs/web.lab.local.crt -noout -subject -issuer -dates -ext subjectAltName,extendedKeyUsage
openssl x509 -in $PKI_DIR/issuing/issuing-ca.crt -noout -ext basicConstraints,keyUsage
cat $PKI_DIR/issuing/index.txt          # the CA database: V = valid, R = revoked
```

**Things to try**

- Issue your own certificate: `./scripts/02_pki_issue.sh server api.lab.local 30`.
- Verify without the intermediate:
  `openssl verify -CAfile $PKI_DIR/root/root-ca.crt $PKI_DIR/certs/web.lab.local.crt` fails with
  *unable to get local issuer certificate*. This is the most common TLS misconfiguration in production.
- Prove the root key really is in the HSM: compare `openssl x509 -in $PKI_DIR/root/root-ca.crt
  -noout -pubkey` with `run/hsm-demo/root-ca-pub.pem` from module 01.

## Module 02b: revocation and CRL (`make revoke`)

**Goal:** take a compromised certificate out of service.

**What happens:** the laptop certificate verifies with CRL checking, is revoked with reason
`keyCompromise`, a new CRL is signed **inside the HSM** by the issuing key, and the same check now fails.

```text
==> After revocation, the same check fails:
error 23 at 0 depth lookup: certificate revoked
```

**Why a CRL exists, in plain terms.** A certificate is an ID card signed by the CA, with an expiry
date. Sometimes you must cancel one *before* it expires: a contractor leaves, a laptop is stolen,
a key leaks. But the certificate itself cannot change; it is still correctly signed and still within
its dates, so on its own it looks valid. The **CRL (Certificate Revocation List)** is the
outside source of truth: a list of cancelled serial numbers, signed by the CA (here, inside the HSM).
Clients check the serial against it, like a shop checking a card against the bank's list of stolen
cards.

**Why it must be republished.** Every CRL carries a *Next Update* date (7 days in this lab), which is
the CA's promise to publish a fresh list by then. After that date the list is stale and clients
must choose:

- *fail closed*: reject every certificate from that CA. The result is an outage, though nothing was
  attacked;
- *fail open*: ignore the stale list. Revoked certificates work again, which is a security hole.

Either way you lose, so the `CRLStale` alert fires when fewer than 2 days remain. Republishing is
just `make revoke` again: it notes the certificate is *already revoked* and signs a new CRL, and the
Grafana panel jumps back to about 7 days.

**Things to try**

- Revoke another certificate with a different reason:
  `./scripts/02_pki_revoke.sh web.lab.local superseded`.
- Read the CRL: `openssl crl -in $PKI_DIR/issuing/issuing.crl -noout -text`. Note *Next Update*:
  after that date clients reject the CRL, which is what the `CRLStale` alert guards against.

## Module 03: KMIP key lifecycle (`make kmip-start`, `make kmip-demo`)

**Goal:** manage keys through a KMS protocol, as databases, storage arrays and backup tools do with
CipherTrust Manager.

**What happens**

1. `03_kmip_server.sh start` runs PyKMIP on `127.0.0.1:5696` with **mutual TLS**: the server
   certificate and the CA chain come from module 02, and clients must present a certificate too.
2. `kmip_lifecycle.py` connects with the `kmip-client` certificate and runs:

   | Step | KMIP operation | Resulting state |
   | --- | --- | --- |
   | 1 | Create AES-256 `payments-dek-v1` | Pre-Active |
   | 2-3 | Activate, then Encrypt a record server-side | Active |
   | 4 | Locate by name | Active |
   | 5-6 | Create and activate v2; decrypt with v1 and re-encrypt with v2 | v2 Active |
   | 7 | Revoke v1 (cessation of operation) | Deactivated |
   | 8-9 | Encrypt and decrypt with v1 | both refused |
   | 10 | Destroy v1; Get now fails | Destroyed |
   | 11 | Revoke a second key for key compromise | Compromised |

**Inspect it yourself**

```bash
make kmip-log            # every request the server handles, with the client identity
```

**Things to try**

- Connect without a client certificate:
  `openssl s_client -connect 127.0.0.1:5696 -CAfile $PKI_DIR/chain.pem </dev/null`; the server
  ends the handshake (`alert handshake failure`). That is mutual TLS doing its job.
- Revoke `kmip-client`'s certificate in module 02 and think through what *should* happen. (PyKMIP
  does not check CRLs; production KMS platforms do. Say so if asked.)
- Explain the order of steps 5-7, and why it would differ on a KMS that allows decrypt-only use of
  deactivated keys, as NIST SP 800-57 permits.

## Module 04: monitoring and renewal (`make metrics`, `make renew`, `make monitoring-up`)

**Goal:** see problems coming before they become outages, and remove manual renewals.

**What happens**

- `crypto_exporter.py` reads every certificate, the CA database, the CRL, the HSM tokens (through
  PKCS#11) and the KMIP port, and publishes:

  | Metric | Meaning |
  | --- | --- |
  | `pki_cert_expiry_days{cn,serial,issuer}` | days left on each certificate |
  | `pki_cert_revoked{cn,serial}` | 1 if revoked |
  | `pki_crl_next_update_days{ca}` | days until the CRL goes stale |
  | `hsm_token_present{token}`, `hsm_token_keys{token}` | token health and key count |
  | `kmip_server_up` | KMS reachability |

- `renew_expiring.py` renews every certificate within 15 days of expiry with a **new key pair**
  (`--rekey`), skips revoked certificates, and supports `--dry-run`.
- `make monitoring-up` starts Prometheus with five alert rules and Grafana with a provisioned
  dashboard (setup in [`SETUP-WSL.md`](SETUP-WSL.md), step 7).

**Things to try**

- `.venv/bin/python python/renew_expiring.py --dry-run --threshold 100` shows every certificate as
  due; this is how you would test a policy change safely.
- Schedule the renewal job daily with `crontab -e`:
  `0 6 * * * cd ~/projects/key-management-lab && make renew >> run/renew.log 2>&1`.
- Write a PromQL query for "certificates expiring this week that are not revoked":
  `pki_cert_expiry_days < 7 and on(serial) pki_cert_revoked == 0`.
- **Fire two alerts, then fix them** (needs the monitoring stack, `SETUP-WSL.md` step 7). Run the
  "break" commands, then wait about 6 minutes **before** fixing anything; the alerts' `for:` timers
  have to run out before *Pending* becomes *Firing*:

  ```bash
  ./scripts/02_pki_issue.sh server old-vpn.lab.local 3   # a certificate about to expire
  make kmip-stop                                         # the KMS goes down
  # ... wait, watch http://localhost:9090/alerts ...
  make renew && make kmip-start                          # recover
  ```

- After `make renew`, check that the old `old-vpn` certificate was **replaced, not revoked**:
  `grep old-vpn $PKI_DIR/issuing/index.txt` shows two `V` (valid) lines with different serials.
  Ask yourself when you would also revoke the old one (answer: whenever the reason for rotating is
  a compromise, not just age).
