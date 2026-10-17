# Key lifecycle and controls in this lab

## Key states (NIST SP 800-57 Part 1, KMIP)

| State | Meaning | Where the lab shows it |
| --- | --- | --- |
| Pre-Active | Generated, not yet allowed to protect data | `kmip_lifecycle.py` step 1 |
| Active | May encrypt and decrypt (or sign and verify) | steps 2-4 |
| Deactivated | Retired from new protection; kept for the retention period | step 7 (rotation of v1) |
| Compromised | Suspected or known disclosure; must never protect data again | step 11 |
| Destroyed | Key material erased; only metadata may remain | step 10 |

## Lifecycle operations

| Operation | How the lab does it |
| --- | --- |
| Generation | Inside the HSM (`pkcs11-tool --keypairgen/--keygen`) or by the KMIP server (`Create`) |
| Distribution | Never as plaintext: keys stay in the HSM; data keys travel wrapped by a KEK |
| Rotation | KMIP: new version activated, data re-encrypted, old version deactivated. PKI: renewal with a new key pair (`renew_expiring.py --rekey`) |
| Archival | Deactivated key retained, refused for new encryption |
| Revocation | KMIP `Revoke` (superseded or key compromise); X.509 revocation + CRL |
| Destruction | KMIP `Destroy`; afterwards `Get` fails with ITEM_NOT_FOUND |

## Controls the lab demonstrates, and those it does not

| Control | In the lab | In production |
| --- | --- | --- |
| Non-extractable keys | Yes: `CKA_SENSITIVE`, `CKA_EXTRACTABLE=false`, read refused | Same, enforced in hardware |
| Separation of keys by purpose | Yes: separate tokens for root CA, issuing CA, application KEKs | Separate partitions, separate roles |
| Mutual TLS to the KMS | Yes: client certificate from the lab PKI | Same, plus client registration and quotas |
| Monitoring and alerting | Yes: expiry, CRL freshness, HSM and KMS availability | Same, feeding an on-call rota |
| Dual control / split knowledge (M of N) | No | Luna PED keys or quorum for partition activation and backup |
| FIPS 140-3 validated module | No (SoftHSM is software) | Level 3 HSM for CA and payment keys |
| HSM HA and backup | No | HA groups and backup HSMs |
| Tamper-evident audit log | Partial (PyKMIP server log) | Signed HSM audit logs shipped to a SIEM |
