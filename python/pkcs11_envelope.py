"""Module 01c -- Envelope encryption through PKCS#11, and proof that HSM keys cannot be read out.

Pattern used by HSM-backed applications and by KMS platforms such as CipherTrust Manager:
  1. A key-encryption key (KEK) lives in the HSM and never leaves it.
  2. Each piece of data gets its own data-encryption key (DEK).
  3. The DEK encrypts the data, then the KEK *wraps* (encrypts) the DEK.
  4. Only the wrapped DEK and the ciphertext are stored outside the HSM.

Run:  source config/lab.env && .venv/bin/python python/pkcs11_envelope.py
"""
import os
import sys

import pkcs11
from pkcs11 import Attribute, KeyType, Mechanism, ObjectClass
from pkcs11.exceptions import AttributeSensitive

lib = pkcs11.lib(os.environ["PKCS11_MODULE"])
token = lib.get_token(token_label="app-keys")


def show(step, text):
    print(f"[{step}] {text}")


with token.open(user_pin=os.environ["USER_PIN"], rw=True) as session:
    kek = session.get_key(object_class=ObjectClass.SECRET_KEY, label="kek-v1")
    show(1, f"KEK found in HSM: label={kek.label}, type=AES-{kek[Attribute.VALUE_LEN] * 8}, "
            f"sensitive={kek[Attribute.SENSITIVE]}, extractable={kek[Attribute.EXTRACTABLE]}")

    # Proof 1: the KEK's key material cannot be read.
    try:
        _ = kek[Attribute.VALUE]
        show(2, "UNEXPECTED: KEK value was readable")
        sys.exit(1)
    except AttributeSensitive:
        show(2, "Reading the KEK's value -> CKR_ATTRIBUTE_SENSITIVE (refused by the HSM, as designed)")

    # Step 3: a fresh DEK for one record. It is a session object (token=False): it disappears
    # when the session closes, so the only lasting copy is the wrapped one.
    dek = session.generate_key(
        KeyType.AES, 256, store=False, label="dek-temp",
        template={Attribute.EXTRACTABLE: True, Attribute.SENSITIVE: False},
    )
    record = b"customer=4411; card_last4=0042; limit=25000 CAD"
    iv = session.generate_random(128)
    ciphertext = dek.encrypt(record, mechanism=Mechanism.AES_CBC_PAD, mechanism_param=iv)
    show(3, f"DEK generated and used: {len(record)}-byte record -> {len(ciphertext)}-byte ciphertext")

    # Step 4: wrap the DEK under the KEK (RFC 5649 AES key wrap with padding).
    wrapped_dek = kek.wrap_key(dek, mechanism=Mechanism.AES_KEY_WRAP_PAD)
    show(4, f"DEK wrapped by KEK -> {len(wrapped_dek)} bytes; store this next to the ciphertext")

    # Later, possibly in another process: unwrap the DEK inside the HSM, then decrypt.
    dek2 = kek.unwrap_key(ObjectClass.SECRET_KEY, KeyType.AES, wrapped_dek,
                          mechanism=Mechanism.AES_KEY_WRAP_PAD, store=False,
                          template={Attribute.SENSITIVE: True})
    plaintext = dek2.decrypt(ciphertext, mechanism=Mechanism.AES_CBC_PAD, mechanism_param=iv)
    assert plaintext == record
    show(5, "Unwrapped the DEK inside the HSM and decrypted the record: round trip OK")

    # Proof 2: the unwrapped DEK was marked sensitive, so it cannot be read either.
    try:
        _ = dek2[Attribute.VALUE]
        show(6, "UNEXPECTED: unwrapped DEK value was readable")
        sys.exit(1)
    except AttributeSensitive:
        show(6, "Unwrapped DEK is sensitive too: its value never appears outside the HSM")

print("\nEnvelope encryption works: the KEK never left the token; only ciphertext and the wrapped DEK did.")
