#!/usr/bin/env bash
# Install everything the lab needs. Target: Ubuntu 24.04 (native, WSL 2, or GitHub Actions).
set -euo pipefail
cd "$(dirname "$0")/.."

# --- 1. Operating system check -------------------------------------------------
. /etc/os-release
echo "==> Detected $PRETTY_NAME"
if [ "${VERSION_ID:-}" != "24.04" ]; then
  echo "    WARNING: the lab is tested on Ubuntu 24.04. The OpenSSL PKCS#11 provider"
  echo "    (package pkcs11-provider) is not available on 22.04 and older."
  echo "    On WSL, install 24.04 from PowerShell:  wsl --install -d Ubuntu-24.04"
fi

# --- 2. System packages --------------------------------------------------------
echo "==> System packages: SoftHSM2, OpenSC (pkcs11-tool), OpenSSL PKCS#11 provider"
sudo apt-get update -q
if ! apt-cache show pkcs11-provider >/dev/null 2>&1; then
  echo "    ERROR: package 'pkcs11-provider' not found in your apt sources. Use Ubuntu 24.04."; exit 1
fi
sudo apt-get install -y -q softhsm2 opensc pkcs11-provider openssl make curl unzip python3-venv

# --- 3. uv: fast Python installer that can also fetch Python 3.11 ---------------
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null; then
  echo "==> Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# --- 4. Python environments ----------------------------------------------------
echo "==> .venv      : python-pkcs11, prometheus-client, cryptography (system Python)"
uv venv -q --allow-existing .venv
uv pip install -q --python .venv/bin/python python-pkcs11 prometheus-client cryptography

echo "==> .venv-kmip : PyKMIP on Python 3.11 (PyKMIP does not run on Python 3.12+)"
uv venv -q --allow-existing --python 3.11 .venv-kmip
uv pip install -q --python .venv-kmip/bin/python pykmip "sqlalchemy<2.0"

chmod +x scripts/*.sh
echo
echo "Install complete. Next:  make doctor   then   make demo"
