# Deploying a Python Web App to a DigitalOcean Droplet

These steps assume a fresh Ubuntu droplet. They are split into two phases: hardening the server first, then deploying the app. Do not skip or reorder the hardening steps — some mistakes (like enabling a firewall before allowing SSH) will permanently lock you out.

---

## Phase 1 — Harden the server (one-time setup)

### Step 1 — SSH in as root for the last time

```bash
ssh root@YOUR_DROPLET_IP
```

A fresh droplet only has a root account. Root is the superuser — it has unrestricted access to every file, process, and configuration on the machine. That makes it a high-value target: automated bots continuously scan the internet for servers accepting root SSH logins and attempt to brute-force or exploit them.

The safer model is to create a normal user that can run privileged commands only when explicitly needed (via `sudo`), and then disable root SSH access entirely. This way, even if an attacker guesses your password or finds a vulnerability, they land in a restricted account rather than immediately owning the machine. You will use root briefly to set this up and then close the door behind you.

### Step 2 — Update the system package index

```bash
apt update && apt upgrade -y
```

These are two separate commands chained together:

- `apt update` refreshes the local list of available packages and their versions by downloading metadata from the configured package repositories. It does not install or change anything — it only updates what the system *knows* is available.
- `apt upgrade` installs the newest version of every package that is already installed, based on the list just fetched. Without running `update` first, `upgrade` would work from a stale list and potentially miss recent security patches.
- `-y` automatically answers "yes" to the confirmation prompt so the command can run without manual input.

A fresh droplet's package list is often days or weeks out of date. Running both before installing anything ensures you start from a current, patched baseline.

### Step 3 — Set up the firewall before opening any ports

```bash
ufw allow OpenSSH   # do this first — skipping it locks you out permanently
ufw enable
ufw status
```

**What a port is**
Every service on a server listens on a numbered port — think of ports as doors into the machine. SSH uses port 22. Web traffic uses port 80 (HTTP) or 443 (HTTPS). Your app will use whichever port you configure it on (e.g. 8000). When you connect to a server, your computer knocks on a specific door and the server either answers or ignores it.

**What a firewall does**
By default, a fresh droplet has all ports open — anyone on the internet can attempt to connect to any service running on the machine. A firewall sits in front of those doors and enforces a ruleset: only the ports you explicitly allow can receive traffic. Everything else is silently dropped.

**What UFW is**
UFW (Uncomplicated Firewall) is a tool for managing these rules on Ubuntu. It wraps the lower-level Linux firewall (`iptables`) in simpler commands.

**What each command does**
- `ufw allow OpenSSH` — adds a rule permitting traffic on port 22, which is the port SSH uses. `OpenSSH` is a named shortcut UFW understands; you could also write `ufw allow 22`.
- `ufw enable` — activates the firewall and starts enforcing the ruleset immediately.
- `ufw status` — lists all current rules so you can confirm what is and isn't allowed.

**Why the order is critical**
The moment you run `ufw enable`, the firewall turns on and blocks everything that isn't explicitly allowed. If you run `enable` before `allow OpenSSH`, your SSH connection — which is how you are controlling the server — gets cut off immediately, with no way to reconnect. The droplet is still running, but you are locked outside with no door to knock on. You would have to destroy the droplet and start over.

### Step 4 — Create a non-root sudo user

```bash
adduser deploy                        # prompts for a password — use a strong one
usermod -aG sudo deploy               # grant sudo privileges
```

**What each command does**
- `adduser deploy` creates a new user account named `deploy` with a home directory (`/home/deploy`) and prompts you to set a password. The name `deploy` is just a convention — you can call it anything.
- `usermod -aG sudo deploy` adds the `deploy` user to the `sudo` group. `-aG` means "append to group" — without the `-a` flag it would replace all existing groups instead of adding to them, which could break things.

**Why not just stay as root**
When you are root, every command you run — whether intentional or not — executes with full system privileges. A typo like `rm -rf /opt /myapp` (notice the accidental space) would wipe the entire `/opt` directory before you could stop it. A misconfigured script, a vulnerable dependency, or a compromised package would have the same unrestricted access. There is no safety net.

**What sudo gives you instead**
`sudo` (short for "superuser do") lets a normal user run a single command with elevated privileges by prefixing it. The rest of the time you operate without those privileges. This is safer in several ways:

- **Intentionality** — you have to consciously type `sudo` each time, which makes accidental destructive commands less likely
- **Auditing** — every `sudo` command is logged in `/var/log/auth.log` with a timestamp and the username, so there is a record of what was done and when
- **Timeout** — sudo privileges expire after a short period (typically 15 minutes) and require your password again, so a session left unattended doesn't stay dangerous indefinitely
- **Blast radius** — if your session is hijacked or a process you run is compromised, the attacker operates as `deploy`, not root. They would still need to escalate privileges separately to do lasting damage to the system.

### Step 5 — Copy your SSH key to the new user

```bash
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy
```

**What this is copying**
When DigitalOcean created the droplet, it placed your public SSH key in `/root/.ssh/authorized_keys`. That file is what lets you log in as root without a password — the server checks incoming connections against it. The `deploy` user has no such file yet, so SSH would reject any attempt to log in as them.

**What the command does**
- `rsync` is a file copying tool. It is used here instead of `cp` because it handles permissions more reliably.
- `--archive` preserves file permissions, timestamps, and ownership structure exactly as they are. SSH is strict about permissions on key files — if they are too open (readable by others), it refuses to use them as a security measure.
- `--chown=deploy:deploy` changes the ownership of everything copied to the `deploy` user and `deploy` group. Without this, the files would still be owned by root, and `deploy` would not be able to read them.
- `~/.ssh` is the source — root's SSH directory.
- `/home/deploy` is the destination — the `deploy` user's home directory.

The result is that `deploy` now has the same authorized key as root, so your laptop can authenticate as `deploy` the same way it authenticates as root.

**Why this must happen before the next step**
The next step disables root login. If you do that before copying the key, you lose both root access and the only way to log in as `deploy`. The droplet becomes permanently unreachable and you would have to destroy and recreate it.

### Step 6 — Disable root login and password authentication

```bash
nano /etc/ssh/sshd_config
```

`nano` is a simple terminal text editor. Use the arrow keys to navigate, and `Ctrl+X` then `Y` then `Enter` to save and exit.

`sshd_config` is the configuration file for the SSH server (the `d` in `sshd` stands for daemon — a background process that runs continuously waiting for incoming connections). Changes here control how the server handles all incoming SSH connections.

Find and set these lines (add them if missing):

```
PermitRootLogin no
PasswordAuthentication no
```

- `PermitRootLogin no` — tells the SSH server to refuse any login attempt for the `root` username, regardless of whether the key or password is correct. Root is the one account that exists on every Linux server, so it is the first thing attackers try. Removing it from SSH access entirely eliminates that target.
- `PasswordAuthentication no` — tells the SSH server to stop accepting passwords as a way to log in. Instead, only SSH key pairs are accepted. This shuts down brute-force attacks completely: a brute-force attack works by trying thousands of password combinations per second, but there is no password to guess if password authentication is disabled. Without a copy of your private key file, there is no way in.

Then restart SSH to apply:

```bash
systemctl restart ssh
```

Changes to `sshd_config` do not take effect until the SSH server process is restarted. `systemctl restart ssh` stops and restarts it, loading the new configuration. Your current session stays open — the restart only affects new incoming connections.

### Step 7 — Verify you can log in as the new user before closing root session

Open a **new terminal window** and test:

```bash
ssh deploy@YOUR_DROPLET_IP
```

Do not close the root session until this works. If you close root first and the new login fails, you are locked out. Once confirmed, you can close the root session. All future connections use `deploy`.

---

## Phase 2 — Deploy the app

From here, SSH in as `deploy` and prefix privileged commands with `sudo`.

### Step 8 — Install Git

```bash
sudo apt install -y git
git --version   # confirm it installed
```

Git is not always present on a minimal droplet image. You need it to clone your repo and pull updates later.

### Step 9 — Install uv (Python toolchain)

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.bashrc   # reload PATH so the uv binary is found
uv --version       # confirm it installed
```

`uv` manages both Python versions and virtual environments. It replaces separate installs of `python3`, `pip`, and `venv`. Reloading the shell profile is required because the installer adds `uv` to `~/.local/bin`, which isn't in `PATH` until the profile is re-read.

### Step 10 — Create a dedicated system user for the app

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin appuser
```

The app process should run with the minimum permissions it needs — not as `deploy` (which has sudo) and certainly not as root. A system user with no home directory and no login shell cannot be used to open an interactive session, so even if the app is compromised, the attacker gets a heavily restricted account.

### Step 11 — Clone the repository

```bash
sudo git clone YOUR_REPO_URL /opt/myapp
sudo chown -R appuser:appuser /opt/myapp
```

`/opt` is the conventional location for third-party applications on Linux. Assigning ownership to `appuser` means the app process can read and write its own files but has no access to anything else on the system.

### Step 12 — Create a virtual environment and install dependencies

```bash
sudo -u appuser bash -c "cd /opt/myapp && uv venv && .venv/bin/pip install -r requirements.txt"
```

Running this as `appuser` ensures the virtual environment and installed packages are owned by the app user, not by `deploy` or root. A virtual environment isolates the app's packages so system upgrades cannot silently break it.

### Step 13 — Open the app's port in the firewall

```bash
sudo ufw allow YOUR_APP_PORT
sudo ufw status
```

Replace `YOUR_APP_PORT` with whichever port your app listens on (e.g. 8000). This must be done after enabling UFW (Step 3) so the rule is added to an already-active firewall.

### Step 14 — Create a systemd service

```bash
sudo nano /etc/systemd/system/myapp.service
```

Paste the following, replacing `YOUR_START_COMMAND`:

```ini
[Unit]
Description=My app
After=network.target

[Service]
User=appuser
Group=appuser
WorkingDirectory=/opt/myapp
ExecStart=/opt/myapp/.venv/bin/YOUR_START_COMMAND
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

`systemd` is the Linux-native service manager — the right tool for keeping a process running persistently. Do not use `screen` or `nohup`: they don't survive reboots and don't restart the app on crash.

- `User=appuser` — runs the process as the restricted app user, not root or deploy
- `After=network.target` — waits for networking before starting so the app can bind its port
- `Restart=on-failure` — restarts automatically if the process exits with an error
- `NoNewPrivileges=true` — prevents the process from escalating its own privileges
- `PrivateTmp=true` — gives the process an isolated `/tmp`, so it cannot read temp files from other processes
- `WantedBy=multi-user.target` — registers the service to start on normal system boot

### Step 15 — Enable and start the service

```bash
sudo systemctl daemon-reload        # tells systemd to read the new unit file
sudo systemctl enable myapp         # registers it to start automatically on boot
sudo systemctl start myapp          # starts it right now, without rebooting
sudo systemctl status myapp         # confirm it is active and running
```

`enable` and `start` are separate operations. `enable` alone does not start the service immediately. `start` alone does not persist across reboots. You need both.

### Step 16 — Verify the app is reachable

```bash
curl http://localhost:YOUR_APP_PORT
```

If the app responds, it is up and listening. Then test from outside by visiting `http://YOUR_DROPLET_IP:YOUR_APP_PORT` in a browser.

---

## Updating the app

```bash
ssh deploy@YOUR_DROPLET_IP
cd /opt/myapp
sudo git pull
sudo chown -R appuser:appuser /opt/myapp
sudo systemctl restart myapp
sudo systemctl status myapp
```

---

## Useful commands

```bash
sudo journalctl -u myapp -f              # tail live logs
sudo systemctl stop myapp               # stop the app
sudo systemctl restart myapp            # restart after changes
sudo fuser -k YOUR_APP_PORT/tcp         # kill anything else holding the port
```

---

## Deploying with Terraform

### Installing Terraform (Mac)

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform -version   # confirm it installed
```

If you don't have Homebrew: install it from [brew.sh](https://brew.sh), then run the commands above.

### What each file is for

```
├── main.tf                   # The infrastructure definition — droplet, firewall, SSH key
├── variables.tf              # Declares all input variables and their types/defaults
├── outputs.tf                # What Terraform prints after apply (IP address, app URL)
├── user_data.sh              # Bootstrap script that runs once on first boot
├── terraform.tfvars.example  # A safe template showing what values are needed
├── terraform.tfvars          # Your actual secret values — never commit this
└── .gitignore                # Excludes tfvars, state files, and the .terraform directory
```

- **`main.tf`** is the core. It describes what resources to create on DigitalOcean: the droplet, the firewall rules, and the SSH key. Terraform reads this and figures out what API calls to make.
- **`variables.tf`** lists every input the scripts accept (token, repo URL, port, etc.) without storing any values. It's the contract — `main.tf` references these, and you supply the actual values in `terraform.tfvars`.
- **`outputs.tf`** tells Terraform what to print when provisioning is done — in this case the droplet's IP address and the app URL so you don't have to look them up manually.
- **`user_data.sh`** is a shell script that DigitalOcean runs automatically on the droplet the first time it boots. It handles everything in the manual guide: installing software, creating users, hardening SSH, and starting the app as a service.
- **`terraform.tfvars.example`** is a committed template that shows what variables need values. It contains no real secrets — just placeholders. Copy it to `terraform.tfvars` and fill it in.
- **`terraform.tfvars`** is your personal copy with real values: your API token, passwords, and repo URL. It is excluded from git and must never be committed.

### What to commit to GitHub

Terraform files are typically kept in version control, but not all of them:

| File | Commit? | Reason |
|---|---|---|
| `main.tf` | ✅ Yes | Infrastructure definition, no secrets |
| `variables.tf` | ✅ Yes | Variable declarations, no secrets |
| `outputs.tf` | ✅ Yes | Output definitions, no secrets |
| `user_data.sh` | ✅ Yes | Bootstrap script, no secrets |
| `terraform.tfvars.example` | ✅ Yes | Safe template with placeholders |
| `.gitignore` | ✅ Yes | Protects against accidental commits |
| `terraform.tfvars` | ❌ Never | Contains your API token and passwords |
| `.terraform/` | ❌ Never | Downloaded provider binaries, large and machine-specific |
| `terraform.tfstate` | ❌ Never | Records real infrastructure state, may contain secrets |
| `terraform.tfstate.backup` | ❌ Never | Same as above |

The `.gitignore` in the terraform directory already excludes the files that should never be committed. Do not override it.

Terraform automates everything in the manual guide except one step: verifying that your new `deploy` user login works before closing the root session. Since Terraform provisions the SSH key via the DigitalOcean API, you can be confident the key is correctly placed — but you should still SSH in as `deploy` after `apply` completes to confirm before relying on the server.

The bootstrap script (`user_data.sh`) runs once on first boot and handles:
- System updates
- UFW firewall setup
- Installing git and uv
- Creating the `deploy` sudo user and copying your SSH key to them
- Disabling root SSH login and password authentication
- Creating the restricted `appuser` to run the app
- Cloning the repo, installing dependencies, and starting the app as a systemd service

### Setup

```bash
# 1. Copy and fill in your credentials
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in all values. The required ones:

| Variable | Description |
|---|---|
| `do_token` | DigitalOcean API token |
| `repo_url` | HTTPS URL of your GitHub repo |
| `deploy_password` | Password for the `deploy` user (used for sudo) |
| `start_command` | Command to start the app (e.g. `uvicorn main:app --host 0.0.0.0 --port 8000`) |

### Apply

```bash
# 2. Initialize (downloads the DigitalOcean provider)
terraform init

# 3. Preview what will be created
terraform plan

# 4. Create the droplet
terraform apply
```

After `apply`, Terraform prints the droplet IP and app URL. The bootstrap script runs in the background — wait about 2 minutes for it to complete before testing.

### Verify

```bash
# Confirm you can log in as deploy (not root)
ssh deploy@YOUR_DROPLET_IP

# Check the app is running
curl http://YOUR_DROPLET_IP:YOUR_APP_PORT
```

### Tear down

```bash
terraform destroy
```

---

## Common issues

| Problem | Fix |
|---|---|
| Port already in use | `sudo fuser -k YOUR_APP_PORT/tcp` |
| `uv: command not found` | `source ~/.bashrc` or `export PATH="$HOME/.local/bin:$PATH"` |
| App starts but isn't reachable | Check `ufw status` — the port may not be open |
| Updated code not showing | `sudo git pull` then `sudo systemctl restart myapp` |
| Service fails to start | `sudo journalctl -u myapp -n 50` to see the error |
