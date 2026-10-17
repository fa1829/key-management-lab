"""Module 04a -- Prometheus exporter for the health of the crypto estate.

Metrics
  pki_cert_expiry_days{cn,serial,issuer}   days until each certificate expires (negative = expired)
  pki_cert_revoked{cn,serial}              1 if the issuing CA has revoked it
  pki_crl_next_update_days{ca}             days until the published CRL goes stale
  hsm_token_present{token}                 1 if the HSM token answers on PKCS#11
  hsm_token_keys{token}                    number of key objects in the token
  kmip_server_up                           1 if the KMIP port accepts connections

Run:   source config/lab.env && .venv/bin/python python/crypto_exporter.py          (serves :9105/metrics)
       source config/lab.env && .venv/bin/python python/crypto_exporter.py --once   (print once and exit)
"""
import datetime as dt
import glob
import os
import socket
import sys
import time

import pkcs11
from cryptography import x509
from prometheus_client import CollectorRegistry, Gauge, generate_latest, start_http_server

PKI = os.environ["PKI_DIR"]
TOKENS = ["root-ca", "issuing-ca", "app-keys"]
reg = CollectorRegistry()
g_exp = Gauge("pki_cert_expiry_days", "Days until certificate expiry", ["cn", "serial", "issuer"], registry=reg)
g_rev = Gauge("pki_cert_revoked", "Certificate revoked by its CA (1/0)", ["cn", "serial"], registry=reg)
g_crl = Gauge("pki_crl_next_update_days", "Days until the CRL must be republished", ["ca"], registry=reg)
g_tok = Gauge("hsm_token_present", "HSM token reachable via PKCS#11 (1/0)", ["token"], registry=reg)
g_keys = Gauge("hsm_token_keys", "Key objects stored in the token", ["token"], registry=reg)
g_kmip = Gauge("kmip_server_up", "KMIP server port reachable (1/0)", registry=reg)


def now():
    return dt.datetime.now(dt.timezone.utc)


def revoked_serials():
    """Read the issuing CA database: lines starting with 'R' are revoked."""
    out = set()
    try:
        with open(f"{PKI}/issuing/index.txt") as fh:
            for line in fh:
                parts = line.split("\t")
                if parts and parts[0] == "R":
                    out.add(parts[3].upper())
    except FileNotFoundError:
        pass
    return out


def collect():
    g_exp.clear(); g_rev.clear()
    revoked = revoked_serials()
    for path in sorted(glob.glob(f"{PKI}/certs/*.crt")):
        cert = x509.load_pem_x509_certificate(open(path, "rb").read())
        cn = cert.subject.get_attributes_for_oid(x509.NameOID.COMMON_NAME)[0].value
        issuer = cert.issuer.get_attributes_for_oid(x509.NameOID.COMMON_NAME)[0].value
        serial = format(cert.serial_number, "X")
        days = (cert.not_valid_after_utc - now()).total_seconds() / 86400
        g_exp.labels(cn, serial, issuer).set(round(days, 2))
        g_rev.labels(cn, serial).set(1 if serial in revoked else 0)

    crl_path = f"{PKI}/issuing/issuing.crl"
    if os.path.exists(crl_path):
        crl = x509.load_pem_x509_crl(open(crl_path, "rb").read())
        g_crl.labels("Lab Issuing CA 1").set(round((crl.next_update_utc - now()).total_seconds() / 86400, 2))

    lib = pkcs11.lib(os.environ["PKCS11_MODULE"])
    for label in TOKENS:
        try:
            tok = lib.get_token(token_label=label)
            g_tok.labels(label).set(1)
            with tok.open(user_pin=os.environ["USER_PIN"]) as s:
                n = sum(1 for o in s.get_objects()
                        if o.object_class in (pkcs11.ObjectClass.PRIVATE_KEY, pkcs11.ObjectClass.SECRET_KEY))
            g_keys.labels(label).set(n)
        except Exception:  # noqa: BLE001 -- a missing token is exactly what we want to alert on
            g_tok.labels(label).set(0)

    try:
        with socket.create_connection(("127.0.0.1", 5696), timeout=1):
            g_kmip.set(1)
    except OSError:
        g_kmip.set(0)


if __name__ == "__main__":
    collect()
    if "--once" in sys.argv:
        sys.stdout.write(generate_latest(reg).decode())
        sys.exit(0)
    port = int(os.environ.get("EXPORTER_PORT", "9105"))
    start_http_server(port, addr="0.0.0.0", registry=reg)
    print(f"crypto exporter on http://0.0.0.0:{port}/metrics (refresh every 15 s)")
    while True:
        time.sleep(15)
        collect()
