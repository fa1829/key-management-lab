#!/usr/bin/env bash
# Pre-flight check: tells you exactly what is missing before you run the lab.
cd "$(dirname "$0")/.."
source config/lab.env
ok=0; warn=0; fail=0
pass() { printf "  [ OK ]  %s\n" "$1"; ok=$((ok+1)); }
note() { printf "  [WARN]  %s\n" "$1"; warn=$((warn+1)); }
bad()  { printf "  [FAIL]  %s\n" "$1"; fail=$((fail+1)); }

echo "Environment"
. /etc/os-release
[ "${VERSION_ID:-}" = "24.04" ] && pass "Ubuntu 24.04" || note "$PRETTY_NAME (tested on Ubuntu 24.04)"
grep -qi microsoft /proc/version 2>/dev/null && pass "running inside WSL" || pass "running on native Linux"
case "$LAB_HOME" in /mnt/*) note "lab is on the Windows drive ($LAB_HOME): move it to ~/projects for speed and file permissions";; *) pass "lab is on the Linux filesystem";; esac
[ -x scripts/01_hsm_init.sh ] && pass "scripts are executable" || bad "scripts not executable: run  chmod +x scripts/*.sh"
if grep -l $'\r' scripts/*.sh config/lab.env >/dev/null 2>&1; then bad "Windows line endings found: run  sed -i 's/\\r\$//' scripts/*.sh config/lab.env"; else pass "Unix line endings"; fi

echo "HSM and PKI tools"
command -v softhsm2-util >/dev/null && pass "softhsm2-util $(softhsm2-util --version)" || bad "SoftHSM2 missing: make install"
[ -f "$PKCS11_MODULE" ] && pass "PKCS#11 module $PKCS11_MODULE" || bad "PKCS#11 module not found at $PKCS11_MODULE"
command -v pkcs11-tool >/dev/null && pass "pkcs11-tool (OpenSC)" || bad "OpenSC missing: make install"
[ -f "$PKCS11_PROVIDER" ] && pass "OpenSSL PKCS#11 provider" || bad "pkcs11-provider missing at $PKCS11_PROVIDER: make install"
openssl version | grep -q "OpenSSL 3" && pass "$(openssl version | cut -d' ' -f1-2)" || bad "OpenSSL 3 required"

echo "Python environments"
[ -x .venv/bin/python ] && .venv/bin/python -c "import pkcs11, prometheus_client, cryptography" 2>/dev/null \
  && pass ".venv: python-pkcs11, prometheus-client, cryptography" || bad ".venv incomplete: make install"
[ -x .venv-kmip/bin/python ] && .venv-kmip/bin/python -c "import kmip" 2>/dev/null \
  && pass ".venv-kmip: PyKMIP on $(.venv-kmip/bin/python --version)" || bad ".venv-kmip incomplete: make install"

echo "Ports"
for p in 5696 9105 9090 3000; do
  if (echo > /dev/tcp/127.0.0.1/$p) 2>/dev/null; then note "port $p already in use (fine if it is this lab)"; else pass "port $p free"; fi
done

echo "Monitoring (optional)"
if command -v docker >/dev/null; then
  docker info >/dev/null 2>&1 && pass "Docker daemon reachable" || note "docker installed but daemon not reachable: sudo service docker start, or add yourself to the docker group"
  docker compose version >/dev/null 2>&1 && pass "docker compose plugin" || note "docker compose plugin missing: sudo apt install docker-compose-v2"
else
  note "Docker not installed: needed only for make monitoring-up (see docs/SETUP-WSL.md, step 7)"
fi

echo
echo "Summary: $ok ok, $warn warnings, $fail failures"
[ "$fail" -eq 0 ] && echo "Ready: run  make demo" || { echo "Fix the failures above, then run  make doctor  again."; exit 1; }
