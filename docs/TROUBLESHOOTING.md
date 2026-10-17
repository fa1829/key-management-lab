# Troubleshooting

Start with `make doctor`: it checks the operating system, tools, Python environments, ports and
Docker, and prints the fix for each failure. The table below covers what it cannot.

## Install and environment

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ERROR: package 'pkcs11-provider' not found` | Ubuntu older than 24.04 | In PowerShell: `wsl --install -d Ubuntu-24.04`, then redo the setup in the new distribution |
| `Permission denied` running `./scripts/...` | Zip extracted in Windows, executable bits lost | `chmod +x scripts/*.sh` |
| `/usr/bin/env: 'bash\r': No such file or directory` | Windows line endings | `sed -i 's/\r$//' scripts/*.sh config/lab.env Makefile` |
| Everything is very slow; doctor warns about `/mnt/` | Lab is on the Windows drive | Move it: `mv /mnt/c/.../key-management-lab ~/projects/` |
| `uv: command not found` after install | `~/.local/bin` not on PATH in this shell | `source ~/.bashrc`, or open a new terminal |
| `make install` fails downloading Python 3.11 | No internet from WSL or a proxy | Check `curl -I https://github.com`; behind a VPN, try without it |

## HSM (module 01)

| Symptom | Cause | Fix |
| --- | --- | --- |
| `CKR_PIN_INCORRECT` | Wrong PIN, or you changed `USER_PIN` after tokens were made | `make clean` then `make hsm` to recreate tokens with the current PIN |
| `No slot with token label` | Tokens not created, or `SOFTHSM2_CONF` not set | `make hsm`; for manual commands run `source config/lab.env` first |
| `CKR_MECHANISM_INVALID` on `ECDSA-SHA256` | SoftHSM only offers raw `ECDSA` | Hash first, as `01_hsm_keys.sh` does |
| Old tokens from another run appear | Token directory persists in `run/tokens` | `make clean` |

## PKI (module 02)

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Could not open file or uri for loading private key from pkcs11:...` | OpenSSL not using the lab config | Use the scripts, or `source config/lab.env` (sets `OPENSSL_CONF`) |
| `unable to get local issuer certificate` | Intermediate missing from the check | Add `-untrusted run/pki/issuing/issuing-ca.crt`, or use `run/pki/chain.pem` |
| `TXT_DB error number 2` from `openssl ca` | Same subject issued twice with `unique_subject = yes` | The lab sets `unique_subject = no`; if you edited `ca.cnf`, restore it |
| A normal `openssl` command elsewhere behaves oddly | `OPENSSL_CONF` still points to the lab config in this shell | `unset OPENSSL_CONF`, or open a new terminal |

## KMIP (module 03)

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Cannot reach the KMIP server` | Server not running | `make kmip-start`, then `make kmip-log` |
| Server exits at once; log mentions `wrap_socket` | PyKMIP run with Python 3.12+ | Use `.venv-kmip` (Python 3.11): `make install` recreates it |
| `SSLEOFError` lines in the server log | Port checks by the start script or the exporter | Harmless: they connect without TLS on purpose |
| `Address already in use` on 5696 | Old server still running | `make kmip-stop`; if that fails, `pkill -f pykmip-server` |
| Handshake failure from your own client | Client certificate missing, expired or not from the lab CA | Use `run/pki/certs/kmip-client.crt` and `run/pki/keys/kmip-client.key` |

## Monitoring (module 04)

| Symptom | Cause | Fix |
| --- | --- | --- |
| `permission denied ... docker.sock` | User not in the `docker` group yet | `sudo usermod -aG docker $USER`, then close and reopen the terminal |
| `Cannot connect to the Docker daemon` | Docker not started | `sudo systemctl start docker`, or `sudo service docker start` without systemd |
| Prometheus target `crypto-exporter` is **DOWN** | Exporter not running | Terminal 1: `make exporter` and leave it running |
| Grafana panels say *No data* | Datasource cannot reach Prometheus, or no scrape yet | Wait 30 s; check `http://localhost:9090/targets`; confirm both containers run with `docker ps` |
| Every panel says *No data* except *Certificates expiring* showing **0** | Exporter not running; that panel ends in `or vector(0)`, so it shows 0 even with no data | Terminal 1: `make exporter`; check `http://localhost:9105/metrics` |
| Alerts stay *Pending*, never *Firing* | The problem was fixed before the `for:` timer ran out | Leave it broken for about 6 minutes before running `make renew` / `make kmip-start` |
| `localhost:3000` does not open from Windows | WSL localhost forwarding disabled | Use the WSL IP from `hostname -I`, e.g. `http://172.x.x.x:3000` |

### Using Docker Desktop instead of Docker Engine in WSL

The compose file uses `network_mode: host` so containers reach the exporter on `localhost:9105`.
Docker Desktop supports host networking only when you turn it on (Settings, Resources, Network, in
recent versions). If you cannot turn it on:

1. Find the WSL address: `hostname -I | awk '{print $1}'`.
2. In `monitoring/prometheus.yml` change the target to `"<that address>:9105"`.
3. In `monitoring/docker-compose.yml` remove both `network_mode: host` lines and add
   `ports: ["9090:9090"]` to Prometheus and `ports: ["3000:3000"]` to Grafana.
4. In `monitoring/grafana/provisioning/datasources/prometheus.yml` change the URL to
   `http://prometheus:9090`.

The WSL address changes when WSL restarts, so Docker Engine inside WSL is the simpler choice for
this lab.

## Starting over

```bash
make monitoring-down; make kmip-stop; make clean   # removes run/ only, never your code
make reset                                          # clean + full demo
```
