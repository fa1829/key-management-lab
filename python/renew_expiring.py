"""Module 04b -- Find certificates close to expiry and renew them from the HSM-backed CA.

Policy (edit to taste):
  * renew when fewer than THRESHOLD_DAYS remain (default 15)
  * always generate a NEW key pair on renewal (key rotation, not just certificate re-issue)
  * never renew a revoked certificate -- that needs a human decision

Run:  source config/lab.env && .venv/bin/python python/renew_expiring.py [--threshold 15] [--dry-run]
Schedule it with cron or a systemd timer, e.g.  0 6 * * *  (daily at 06:00).
"""
import argparse
import datetime as dt
import glob
import os
import subprocess

from cryptography import x509
from cryptography.x509.oid import ExtendedKeyUsageOID

ap = argparse.ArgumentParser()
ap.add_argument("--threshold", type=float, default=15)
ap.add_argument("--days", type=int, default=90, help="validity of renewed certificates")
ap.add_argument("--dry-run", action="store_true")
args = ap.parse_args()

PKI = os.environ["PKI_DIR"]
ISSUE = os.path.join(os.environ["LAB_HOME"], "scripts", "02_pki_issue.sh")
revoked = {l.split("\t")[3].upper() for l in open(f"{PKI}/issuing/index.txt") if l.startswith("R")}
now = dt.datetime.now(dt.timezone.utc)
renewed = 0

for path in sorted(glob.glob(f"{PKI}/certs/*.crt")):
    cert = x509.load_pem_x509_certificate(open(path, "rb").read())
    cn = cert.subject.get_attributes_for_oid(x509.NameOID.COMMON_NAME)[0].value
    serial = format(cert.serial_number, "X")
    days = (cert.not_valid_after_utc - now).total_seconds() / 86400
    eku = cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value
    kind = "server" if ExtendedKeyUsageOID.SERVER_AUTH in eku else "client"

    if serial in revoked:
        print(f"SKIP   {cn:<22} revoked -- needs a human decision, not auto-renewal")
    elif days >= args.threshold:
        print(f"OK     {cn:<22} {days:6.1f} days left")
    elif args.dry_run:
        print(f"WOULD  {cn:<22} {days:6.1f} days left -> renew with a new key")
    else:
        out = subprocess.run([ISSUE, kind, cn, str(args.days), "--rekey"],
                             capture_output=True, text=True, check=True).stdout.strip()
        print(f"RENEW  {cn:<22} {days:6.1f} days left -> {out}")
        renewed += 1

print(f"\n{renewed} certificate(s) renewed.")
