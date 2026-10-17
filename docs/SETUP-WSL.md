# Setup guide: from the downloaded zip to a published GitHub repository

This guide takes you from `key-management-lab.zip` in your Windows **Downloads** folder to a working
lab in WSL, a live Grafana dashboard, and a public repository with a passing CI badge.
Every command is typed in the **Ubuntu terminal** unless a step says PowerShell.

| Step | What you do | Time |
| --- | --- | --- |
| 0 | Check WSL and Ubuntu version | 2 min |
| 1 | Copy the zip into Linux and unpack it | 2 min |
| 2 | Install dependencies | 5-10 min |
| 3 | Pre-flight check | 1 min |
| 4 | Run the whole lab | 1 min |
| 5 | Explore module by module | 30-60 min |
| 6 | Install Docker inside WSL (for monitoring) | 10 min |
| 7 | Start Prometheus and Grafana | 5 min |
| 8 | Publish to GitHub | 10 min |
| 9 | Reset, stop, clean up | 1 min |

---

## Step 0: check WSL and Ubuntu

In **PowerShell**:

```powershell
wsl -l -v
```

You need a distribution with `VERSION 2`. Then, in the **Ubuntu terminal**:

```bash
lsb_release -d          # must say Ubuntu 24.04.x LTS
ps -p 1 -o comm=        # 'systemd' is ideal (needed later for Docker as a service)
```

If you are on Ubuntu 22.04 or older, install 24.04 alongside it (your old distribution stays) from
**PowerShell**: `wsl --install -d Ubuntu-24.04`, then open "Ubuntu 24.04" from the Start menu.
The lab needs 24.04 because the OpenSSL PKCS#11 provider package does not exist on 22.04.

## Step 1: copy the zip into the Linux filesystem and unpack it

Work in your Linux home directory, **not** under `/mnt/c`. Files on the Windows drive are slow from
WSL and lose their Linux permissions, which breaks the scripts.

Do **not** unzip in Windows first; unzip inside Ubuntu so the scripts keep their executable bit and
Unix line endings.

```bash
mkdir -p ~/projects && cd ~/projects
ls /mnt/c/Users/                       # find your Windows user name in this list
cp /mnt/c/Users/<YourWindowsName>/Downloads/key-management-lab.zip .
sudo apt-get update && sudo apt-get install -y unzip make git
unzip key-management-lab.zip
cd key-management-lab
ls                                     # Makefile  README.md  config  docs  monitoring  python  scripts
```

You can also open the folder in Windows Explorer from here with `explorer.exe .`, or in VS Code
with `code .`.

## Step 2: install dependencies

```bash
make install
```

This asks for your Ubuntu password once (for `apt`) and then:

1. installs SoftHSM2, OpenSC (`pkcs11-tool`) and the OpenSSL PKCS#11 provider;
2. installs **uv**, a fast Python installer, into `~/.local/bin`;
3. creates `.venv` (system Python) with `python-pkcs11`, `prometheus-client`, `cryptography`;
4. creates `.venv-kmip` with **Python 3.11** and PyKMIP, because PyKMIP does not run on 3.12+.

It ends with `Install complete. Next: make doctor then make demo`.

## Step 3: pre-flight check

```bash
make doctor
```

Every line should be `[ OK ]` except, for now, the Docker lines (you install Docker in step 6).
The last line must read `Ready: run make demo`. Any `[FAIL]` line tells you the exact fix;
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) explains each one.

## Step 4: run the whole lab

```bash
make demo
```

About a minute later you should see, among other output:

```text
Verified OK                                            <- HSM signature checked outside the HSM
[2] Reading the KEK's value -> CKR_ATTRIBUTE_SENSITIVE  <- key material cannot be read
error 23 at 0 depth lookup: certificate revoked          <- revocation works
[10] Destroy v1 ... state=DESTROYED                      <- KMIP lifecycle complete
WOULD  legacy-api.lab.local  5.0 days left -> renew      <- renewal job found an expiring cert
kmip_server_up 1.0                                       <- exporter sees the KMS
```

Compare with [`sample-output.txt`](sample-output.txt). Slot IDs, serial numbers and dates will
differ; everything else should match.

## Step 5: explore module by module

Run the modules one at a time and read what each proves, in
[`MODULES.md`](MODULES.md). Start from a clean state:

```bash
make clean
make hsm
make envelope
make pki
make revoke
make kmip-start
make kmip-demo
make renew-dry && make renew
make status
```

Each section of `MODULES.md` ends with a few **things to try**; they are the best preparation for
interview questions.

## Step 6: install Docker inside WSL (for the monitoring stack)

**First check whether you already have Docker Desktop.** In Ubuntu run `docker version`. If the
*Server* line says `Docker Desktop`, skip this step and read the Docker Desktop note in
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) instead; installing a second Docker would conflict.

Otherwise install Docker Engine from Ubuntu's own repositories:

```bash
sudo apt-get install -y docker.io docker-compose-v2
sudo usermod -aG docker $USER          # lets you run docker without sudo
```

Close the Ubuntu terminal and open it again so the group change applies. Then start Docker:

```bash
sudo systemctl enable --now docker     # if step 0 showed systemd
# or, without systemd:
sudo service docker start
docker run --rm hello-world            # prints "Hello from Docker!"
```

If `ps -p 1 -o comm=` did not print `systemd` and you want Docker to start automatically, add these
lines to `/etc/wsl.conf` (with `sudo nano /etc/wsl.conf`), then run `wsl --shutdown` in PowerShell
and reopen Ubuntu:

```ini
[boot]
systemd=true
```

## Step 7: start Prometheus and Grafana

You need two Ubuntu terminals (open a second tab in Windows Terminal), both in
`~/projects/key-management-lab`.

**Terminal 1** keeps the exporter running:

```bash
make kmip-start
make exporter          # leave it running; Ctrl+C stops it
```

**Terminal 2** starts the containers:

```bash
make monitoring-up
```

Then, in your **Windows browser**:

| URL | What you see |
| --- | --- |
| http://localhost:9105/metrics | raw metrics from the exporter |
| http://localhost:9090/targets | Prometheus: the `crypto-exporter` target should be **UP** |
| http://localhost:9090/alerts | the five alert rules |
| http://localhost:3000 | Grafana (`admin` / `labadmin`): the *Key Management Lab -- Crypto Estate* dashboard opens as the home page |

Make an alert fire, then fix it:

```bash
./scripts/02_pki_issue.sh server old-vpn.lab.local 3     # a 3-day certificate
make kmip-stop                                           # take the KMS down
```

Within a minute both `CertificateExpiringSoon` and `KMIPServerDown` show **Pending** at
`localhost:9090/alerts`, then **Firing** after their `for:` period (2 minutes for the KMS, 5 for the
certificate). **Run the recovery commands only after that.** If you paste everything at once, the
problems are fixed before the timers run out and the alerts never fire. That is correct behaviour,
but it gives you nothing to screenshot. Bring things back:

```bash
make renew           # renews old-vpn.lab.local with a new key
make kmip-start
```

Take screenshots of the dashboard and the alerts page for your README or LinkedIn post. The repo
already has a set in `docs/img/`; to use your own, save them over those files with the same names.

## Step 8: publish to GitHub

1. **Create an empty repository** on github.com named `key-management-lab`: public, and
   **without** a README, licence or .gitignore (the lab already has them).
2. **Set your Git identity** once:

   ```bash
   git config --global user.name  "Khandoker Faisal"
   git config --global user.email "faisaleeeb@gmail.com"
   ```

3. **Commit.** The `.gitignore` keeps `run/` (tokens, keys, certificates) and both virtual
   environments out of Git. Check before committing:

   ```bash
   cd ~/projects/key-management-lab
   git init -b main
   git add .
   git status            # must NOT list run/, .venv/ or .venv-kmip/
   git commit -m "Key management lab: HSM (PKCS#11), PKI, KMIP lifecycle, monitoring"
   ```

4. **Push.** The simplest login is the GitHub CLI:

   ```bash
   sudo apt-get install -y gh
   gh auth login          # GitHub.com > HTTPS > Login with a web browser
   git remote add origin https://github.com/fa1829/key-management-lab.git
   git push -u origin main
   ```

5. **Check CI.** Open the repository's **Actions** tab. The `lab` workflow installs everything on a
   fresh Ubuntu 24.04 runner and runs the full demo; a green tick turns the README badge green.
6. **Make it visible.** Pin the repository on your GitHub profile, add the screenshots from step 7
   to the README, and add one line to your resume's projects section.

## Step 9: reset, stop, clean up

```bash
make monitoring-down     # stop Prometheus and Grafana
make kmip-stop           # stop the KMIP server
make clean               # delete tokens, PKI and KMIP database (run/)
make reset               # clean, then run the whole demo again
```

`make clean` never touches your code, only the generated `run/` directory.
