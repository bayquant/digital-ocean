# Deploying a Python Web App to a DigitalOcean Droplet

These steps assume a fresh Ubuntu droplet. They are split into three phases: hardening the server, deploying the app, then serving it on a domain over HTTPS. Do not skip or reorder the hardening steps: some mistakes (like enabling a firewall before allowing SSH) will permanently lock you out.

The finished setup looks like this:

```
                      Visitor
                         │ https://YOUR_DOMAIN
                         ▼
┌─────────────────────────────────────────────────┐
│ DigitalOcean network                            │
│   Cloud Firewall: only 22, 80, 443 get in       │
└────────────────────────┬────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────┐
│ Droplet                                         │
│   UFW: only 22, 80, 443 get in                  │
│                        │                        │
│                        ▼                        │
│              ┌───────────────────┐              │
│              │ Caddy :80, :443   │              │
│              │ terminates HTTPS  │              │
│              └─────────┬─────────┘              │
│                        │ 127.0.0.1:8000         │
│                        ▼ loopback only          │
│              ┌───────────────────┐              │
│              │ app container     │              │
│              │ uvicorn 0.0.0.0   │              │
│              └───────────────────┘              │
│                                                 │
└─────────────────────────────────────────────────┘
```

Only ports 22, 80 and 443 are reachable from the internet. The app itself is never exposed directly: Caddy receives every request, handles HTTPS, and forwards it to the app over the droplet's internal loopback connection. [How traffic reaches the app](#how-traffic-reaches-the-app) explains each layer.

---

## Phase 1: Harden the server (one-time setup)

### Step 1: SSH in as root for the last time

```bash
ssh root@YOUR_DROPLET_IP
```

A fresh droplet only has a root account. Root is the superuser: it has unrestricted access to every file, process, and configuration on the machine. That makes it a high-value target: automated bots continuously scan the internet for servers accepting root SSH logins and attempt to brute-force or exploit them.

The safer model is to create a normal user that can run privileged commands only when explicitly needed (via `sudo`), and then disable root SSH access entirely. This way, even if an attacker guesses your password or finds a vulnerability, they land in a restricted account rather than immediately owning the machine. You will use root briefly to set this up and then close the door behind you.

### Step 2: Update the system package index

```bash
apt update && apt upgrade -y
```

These are two separate commands chained together:

- `apt update` refreshes the local list of available packages and their versions by downloading metadata from the configured package repositories. It does not install or change anything: it only updates what the system *knows* is available.
- `apt upgrade` installs the newest version of every package that is already installed, based on the list just fetched. Without running `update` first, `upgrade` would work from a stale list and potentially miss recent security patches.
- `-y` automatically answers "yes" to the confirmation prompt so the command can run without manual input.

A fresh droplet's package list is often days or weeks out of date. Running both before installing anything ensures you start from a current, patched baseline.

### Step 3: Set up the firewall before opening any ports

```bash
ufw allow OpenSSH   # do this first: skipping it locks you out permanently
ufw enable
ufw status
```

**What a port is**
Every service on a server listens on a numbered port: think of ports as doors into the machine. SSH uses port 22. Web traffic uses port 80 (HTTP) or 443 (HTTPS). Your app will use whichever port you configure it on (e.g. 8000). When you connect to a server, your computer knocks on a specific door and the server either answers or ignores it.

**What a firewall does**
By default, a fresh droplet has all ports open: anyone on the internet can attempt to connect to any service running on the machine. A firewall sits in front of those doors and enforces a ruleset: only the ports you explicitly allow can receive traffic. Everything else is silently dropped.

**What UFW is**
UFW (Uncomplicated Firewall) is a tool for managing these rules on Ubuntu. It wraps the lower-level Linux firewall (`iptables`) in simpler commands.

**What each command does**
- `ufw allow OpenSSH`: adds a rule permitting traffic on port 22, which is the port SSH uses. `OpenSSH` is a named shortcut UFW understands; you could also write `ufw allow 22`.
- `ufw enable`: activates the firewall and starts enforcing the ruleset immediately.
- `ufw status`: lists all current rules so you can confirm what is and isn't allowed.

**Why the order is critical**
The moment you run `ufw enable`, the firewall turns on and blocks everything that isn't explicitly allowed. If you run `enable` before `allow OpenSSH`, your SSH connection (which is how you are controlling the server) gets cut off immediately, with no way to reconnect. The droplet is still running, but you are locked outside with no door to knock on. You would have to destroy the droplet and start over.

### Step 4: Create a non-root sudo user

```bash
adduser deploy                        # prompts for a password: use a strong one
usermod -aG sudo deploy               # grant sudo privileges
```

**What each command does**
- `adduser deploy` creates a new user account named `deploy` with a home directory (`/home/deploy`) and prompts you to set a password. The name `deploy` is just a convention: you can call it anything.
- `usermod -aG sudo deploy` adds the `deploy` user to the `sudo` group. `-aG` means "append to group": without the `-a` flag it would replace all existing groups instead of adding to them, which could break things.

**Why not just stay as root**
When you are root, every command you run (whether intentional or not) executes with full system privileges. A typo like `rm -rf /opt /myapp` (notice the accidental space) would wipe the entire `/opt` directory before you could stop it. A misconfigured script, a vulnerable dependency, or a compromised package would have the same unrestricted access. There is no safety net.

**What sudo gives you instead**
`sudo` (short for "superuser do") lets a normal user run a single command with elevated privileges by prefixing it. The rest of the time you operate without those privileges. This is safer in several ways:

- **Intentionality**: you have to consciously type `sudo` each time, which makes accidental destructive commands less likely
- **Auditing**: every `sudo` command is logged in `/var/log/auth.log` with a timestamp and the username, so there is a record of what was done and when
- **Timeout**: sudo privileges expire after a short period (typically 15 minutes) and require your password again, so a session left unattended doesn't stay dangerous indefinitely
- **Blast radius**: if your session is hijacked or a process you run is compromised, the attacker operates as `deploy`, not root. They would still need to escalate privileges separately to do lasting damage to the system.

### Step 5: Copy your SSH key to the new user

```bash
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy
```

**What this is copying**
When DigitalOcean created the droplet, it placed your public SSH key in `/root/.ssh/authorized_keys`. That file is what lets you log in as root without a password: the server checks incoming connections against it. The `deploy` user has no such file yet, so SSH would reject any attempt to log in as them.

**What the command does**
- `rsync` is a file copying tool. It is used here instead of `cp` because it handles permissions more reliably.
- `--archive` preserves file permissions, timestamps, and ownership structure exactly as they are. SSH is strict about permissions on key files: if they are too open (readable by others), it refuses to use them as a security measure.
- `--chown=deploy:deploy` changes the ownership of everything copied to the `deploy` user and `deploy` group. Without this, the files would still be owned by root, and `deploy` would not be able to read them.
- `~/.ssh` is the source: root's SSH directory.
- `/home/deploy` is the destination: the `deploy` user's home directory.

The result is that `deploy` now has the same authorized key as root, so your laptop can authenticate as `deploy` the same way it authenticates as root.

**Why this must happen before the next step**
The next step disables root login. If you do that before copying the key, you lose both root access and the only way to log in as `deploy`. The droplet becomes permanently unreachable and you would have to destroy and recreate it.

### Step 6: Disable root login and password authentication

```bash
nano /etc/ssh/sshd_config
```

`nano` is a simple terminal text editor. Use the arrow keys to navigate, and `Ctrl+X` then `Y` then `Enter` to save and exit.

`sshd_config` is the configuration file for the SSH server (the `d` in `sshd` stands for daemon: a background process that runs continuously waiting for incoming connections). Changes here control how the server handles all incoming SSH connections.

Find and set these lines (add them if missing):

```
PermitRootLogin no
PasswordAuthentication no
```

- `PermitRootLogin no`: tells the SSH server to refuse any login attempt for the `root` username, regardless of whether the key or password is correct. Root is the one account that exists on every Linux server, so it is the first thing attackers try. Removing it from SSH access entirely eliminates that target.
- `PasswordAuthentication no`: tells the SSH server to stop accepting passwords as a way to log in. Instead, only SSH key pairs are accepted. This shuts down brute-force attacks completely: a brute-force attack works by trying thousands of password combinations per second, but there is no password to guess if password authentication is disabled. Without a copy of your private key file, there is no way in.

Then restart SSH to apply:

```bash
systemctl restart ssh
```

Changes to `sshd_config` do not take effect until the SSH server process is restarted. `systemctl restart ssh` stops and restarts it, loading the new configuration. Your current session stays open: the restart only affects new incoming connections.

### Step 7: Verify you can log in as the new user before closing root session

Open a **new terminal window** and test:

```bash
ssh deploy@YOUR_DROPLET_IP
```

Do not close the root session until this works. If you close root first and the new login fails, you are locked out. Once confirmed, you can close the root session. All future connections use `deploy`.

---

## Phase 2: Deploy the app

From here, SSH in as `deploy` and prefix privileged commands with `sudo`.

### Step 8: Install Git

```bash
sudo apt install -y git
git --version   # confirm it installed
```

Git is not always present on a minimal droplet image. You need it to clone your repo and pull updates later.

### Step 9: Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker deploy
```

Docker packages your app and all its dependencies into a self-contained image that runs the same way on any machine. The official convenience script (`get.docker.com`) installs Docker's latest stable release from Docker's own package repository.

`usermod -aG docker deploy` adds `deploy` to the `docker` group. By default, only root can run Docker commands. The `docker` group is a way to grant that ability to a normal user without giving them full sudo. This matters because the systemd service in Step 13 will run as `deploy`: it needs to be in the docker group to start and stop containers.

### Step 10: Clone the repository

```bash
sudo git clone YOUR_REPO_URL /opt/myapp
sudo chown -R deploy:deploy /opt/myapp
```

`/opt` is the conventional location for third-party applications on Linux. The repo is owned by `deploy` (rather than root) because `deploy` will be the one building the image and managing the container.

### Step 11: Build the Docker image

```bash
cd /opt/myapp
docker build -t myapp .
```

`docker build` reads the `Dockerfile` in your repo and produces a local image. It installs your app's dependencies inside the image so the server doesn't need a language runtime, a virtual environment, or any of your app's packages installed directly: everything is bundled inside the image.

- `-t myapp` gives the image a name so you can refer to it later
- `.` tells Docker to look for the `Dockerfile` in the current directory

### Step 12: Open HTTP and HTTPS in the firewall

```bash
sudo ufw allow 80
sudo ufw allow 443
sudo ufw status
```

These are the ports Caddy will listen on in Phase 3: 443 serves the site over HTTPS, and 80 is used by Let's Encrypt to verify you control the domain and to redirect plain HTTP visitors to HTTPS. This must be done after enabling UFW (Step 3) so the rules are added to an already-active firewall.

Do **not** open the app's port (e.g. 8000). The app only accepts connections from the droplet itself (see Step 13), and Caddy is the only thing that talks to it.

### Step 13: Create a systemd service

```bash
sudo nano /etc/systemd/system/myapp.service
```

Paste the following, replacing `YOUR_APP_PORT`:

```ini
[Unit]
Description=My app
After=network.target docker.service
Requires=docker.service

[Service]
User=deploy
Restart=on-failure
ExecStartPre=-/usr/bin/docker stop myapp
ExecStartPre=-/usr/bin/docker rm myapp
ExecStart=/usr/bin/docker run --name myapp -p 127.0.0.1:YOUR_APP_PORT:YOUR_APP_PORT myapp
ExecStop=/usr/bin/docker stop myapp

[Install]
WantedBy=multi-user.target
```

`systemd` is the Linux-native service manager: the right tool for keeping a process running persistently. Do not use `screen` or `nohup`: they don't survive reboots and don't restart the app on crash.

- `Requires=docker.service`: the container can't run without the Docker daemon; this tells systemd to start Docker first and stop this service if Docker stops
- `After=network.target docker.service`: waits for both networking and Docker to be ready before starting
- `User=deploy`: runs as `deploy` (who is in the docker group), not root
- `ExecStartPre=-/usr/bin/docker stop myapp`: stops any leftover container from a previous run before starting a new one; the `-` prefix means systemd ignores this if the container doesn't exist yet
- `ExecStartPre=-/usr/bin/docker rm myapp`: removes the stopped container so `docker run` can reuse the name
- `--name myapp`: names the running container so `ExecStop` can reference it
- `-p 127.0.0.1:YOUR_APP_PORT:YOUR_APP_PORT`: forwards the droplet's port into the container, but only on the loopback address `127.0.0.1`, so only programs on the droplet (Caddy) can connect. Without the `127.0.0.1:` prefix, Docker publishes the port on `0.0.0.0` (every network connection), and its own firewall rules bypass UFW: the app would be reachable from the internet even though UFW never allowed the port.
- `Restart=on-failure`: restarts automatically if the process exits with an error
- `WantedBy=multi-user.target`: registers the service to start on normal system boot

### Step 14: Enable and start the service

```bash
sudo systemctl daemon-reload        # tells systemd to read the new unit file
sudo systemctl enable myapp         # registers it to start automatically on boot
sudo systemctl start myapp          # starts it right now, without rebooting
sudo systemctl status myapp         # confirm it is active and running
```

`enable` and `start` are separate operations. `enable` alone does not start the service immediately. `start` alone does not persist across reboots. You need both.

### Step 15: Verify the app is running

```bash
curl http://127.0.0.1:YOUR_APP_PORT
```

If the app responds, it is up and listening. It is not reachable from outside yet, by design: Phase 3 puts it on your domain over HTTPS.

---

## Phase 3: Serve the app on a domain over HTTPS

### Step 16: Buy a domain and point it to DigitalOcean

DigitalOcean does not sell domains: buy one from a registrar (e.g. Porkbun, Namecheap). Use accurate contact details (ICANN requires them, and the registrar can suspend a domain with false ones) and make sure WHOIS privacy is on, so they are not public. Confirm the verification email the registrar sends, or the domain can be suspended.

Then, in the registrar's dashboard, replace its nameservers with DigitalOcean's:

```
ns1.digitalocean.com
ns2.digitalocean.com
ns3.digitalocean.com
```

**What this does**
Three roles are involved, and they are easy to confuse:

| Role | What it does | Here |
|---|---|---|
| Registrar | Records that you own the name | Porkbun, Namecheap, ... |
| DNS host | Answers "what IP is this domain?" | DigitalOcean (after this step) |
| Server | Runs the website | Your droplet |

Changing the nameservers tells the internet that DigitalOcean answers DNS questions for the domain, so the records you create in DigitalOcean (next step) take effect.

> **Cloudflare Registrar** does not allow changing nameservers: DNS must stay on Cloudflare. If you buy there, create the records in Cloudflare instead, and set them to "DNS only" (grey cloud) so Cloudflare's proxy does not interfere with Caddy's certificate.

### Step 17: Create the DNS records

In the DigitalOcean dashboard: **Networking** → **Domains** → add `YOUR_DOMAIN` to your project, then create two **A** records directing to your droplet:

| Type | Hostname | Points to |
|---|---|---|
| A | `@` | your droplet (the bare domain, `YOUR_DOMAIN`) |
| A | `www` | your droplet (`www.YOUR_DOMAIN`) |

DNS answers are cached across the internet, so changes take from a few minutes to a few hours to spread (a brand-new domain is usually fast). Check from your laptop:

```bash
dig +short NS YOUR_DOMAIN   # should list ns1/ns2/ns3.digitalocean.com
dig +short YOUR_DOMAIN      # should print your droplet IP
```

Avoid testing in the browser before `dig` shows the right IP: your computer can cache the "not found" answer and keep showing an error after the domain works for everyone else.

### Step 18: Allow HTTP and HTTPS in the DigitalOcean Cloud Firewall

Skip this if your droplet has no Cloud Firewall attached. Otherwise: **Networking** → **Firewalls** → your firewall → **Inbound Rules** → add **HTTP** (80) and **HTTPS** (443). Remove any rule for the app's port.

UFW (Step 12) and the Cloud Firewall are separate layers, and traffic must pass both. If you deploy with Terraform, change the firewall in `main.tf` instead: Terraform reverts manual dashboard changes on the next `apply`.

### Step 19: Install Caddy

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

Caddy is a web server used here as a **reverse proxy**: it stands in front of the app, receives every request on the standard web ports, forwards it to the app, and sends the reply back. It also handles HTTPS: it obtains a free certificate from Let's Encrypt (the "SSL certificate" that proves the server really is your domain) and renews it before it expires, with no configuration beyond naming the domain. Ubuntu 22.04 does not ship Caddy, so these commands add Caddy's official package repository first.

Caddy is not a load balancer in this setup: a load balancer spreads requests across several copies of an app, while here every request goes to the one app container.

### Step 20: Configure Caddy

```bash
sudo nano /etc/caddy/Caddyfile
```

Replace the whole file with:

```
YOUR_DOMAIN, www.YOUR_DOMAIN {
    reverse_proxy 127.0.0.1:YOUR_APP_PORT
}
```

Then apply it:

```bash
sudo systemctl reload caddy
```

- The first line lists the names Caddy answers for. Naming real domains is what makes Caddy fetch the HTTPS certificate.
- `reverse_proxy 127.0.0.1:YOUR_APP_PORT` forwards every request to the app on the loopback address. Use `127.0.0.1`, not `localhost`: `localhost` can resolve to the IPv6 loopback `::1`, where Docker is not listening (Step 13 binds IPv4 only).

### Step 21: Verify HTTPS

Open `https://YOUR_DOMAIN` in a browser. The first visit can take a few seconds while Caddy obtains the certificate. If it fails:

```bash
sudo journalctl -u caddy -n 50   # Caddy's logs, including certificate errors
```

The most common cause is DNS not pointing at the droplet yet (Step 17) or port 80/443 blocked by one of the firewalls (Steps 12 and 18).

---

## How traffic reaches the app

### Ports and firewalls

Every service on a machine listens on a numbered **port**: 22 for SSH, 80 for HTTP, 443 for HTTPS, 8000 (or similar) for the app. Data travels in **packets**, each labeled with its source IP, destination IP, port and protocol (TCP for web and SSH). A **firewall** checks each incoming packet against its rules and drops anything not explicitly allowed (**default deny**).

This setup has two firewalls, and a packet must pass both:

| | DigitalOcean Cloud Firewall | UFW |
|---|---|---|
| Runs | In DigitalOcean's network, before traffic reaches the droplet | On the droplet, in front of Linux's built-in packet filter |
| Managed from | Dashboard or Terraform (`main.tf`) | `ufw` commands on the droplet |
| Can the droplet change it? | No: a compromised droplet cannot open ports here | Yes |

Both firewalls are **stateful**: rules only control who may *start* a connection, and replies to an allowed connection are let through automatically. That is why outbound responses to visitors need no rule, and why the droplet's own requests (`apt`, `git clone`, Let's Encrypt) get their replies back.

Traffic between programs on the same droplet (Caddy to the app) uses the internal **loopback** connection. It never leaves the machine, so neither firewall applies to it.

### Docker bypasses UFW

`docker run -p` writes its own low-level firewall rules for published ports, and they are checked before UFW's. A port published on `0.0.0.0` is therefore reachable from the internet even if `ufw status` shows it closed. Two defenses apply here: the app is published on `127.0.0.1` only (Step 13), and the Cloud Firewall, which sits outside the droplet and is unaffected by Docker, does not allow the app's port.

### What `0.0.0.0`, `127.0.0.1` and `localhost` mean

The same digits mean different things depending on where they appear:

| Where | Value | Meaning |
|---|---|---|
| A server's listen address | `0.0.0.0` | Accept connections on every network connection the machine has, including the public one |
| A server's listen address | `127.0.0.1` | Accept connections only from the same machine |
| A firewall rule's source | `0.0.0.0/0`, `::/0` | Any IPv4 / IPv6 address on the internet (CIDR notation: `/0` matches everything, `/32` exactly one IPv4 address) |
| A destination to connect to | `localhost` | A name for the same machine, usually `127.0.0.1` and sometimes the IPv6 loopback `::1` |

Applied to this setup:

- **Inside the container, the app listens on `0.0.0.0`** (e.g. `uvicorn --host 0.0.0.0` in the app's Dockerfile). This is required, not a risk: a container has its own network and its own `127.0.0.1`. Docker delivers forwarded traffic through the container's network connection, so an app listening on the container's `127.0.0.1` would refuse everything, Caddy included.
- **On the droplet, the port is published on `127.0.0.1`** (`-p 127.0.0.1:8000:8000`). This is where access is restricted. Rule of thumb: inside a container, always listen on `0.0.0.0`; decide who can reach it with `-p`.
- **Firewall rules for 80 and 443 use `0.0.0.0/0`**, because the site is public. A rule allowing only `127.0.0.1` would match nothing: loopback traffic never crosses the Cloud Firewall.
- **SSH (22) could be narrowed** to your own IP (e.g. `["203.0.113.5/32"]`), at the cost of a lockout whenever your home IP changes. Key-only login (Step 6) already makes brute-forcing it infeasible, so it is left open to all.

### Why `.dev` domains only work over HTTPS

Browsers ship with a built-in **HSTS preload list** of domains that must only ever be loaded over HTTPS. Google, which runs the `.dev` ending, preloaded the entire ending (as with `.app` and `.page`), so browsers silently rewrite `http://` to `https://` for every `.dev` site. Without Caddy (or another HTTPS setup) such a site cannot be opened in a browser at all, even on a plain-HTTP port like `:8000`. Tools like `curl` do not use the preload list, so `curl http://...` still works for testing.

---

> **Docker Compose alternative**
> Instead of a long `docker run` command in the service file, you can put the same configuration into a `docker-compose.yml` file in your repo and deploy with `docker compose up -d`. The Docker installation is identical; only the run step changes. Compose becomes especially useful if you later add a database or cache, since each service is just another entry in the file rather than another long `docker run` command.

---

## Updating the app

```bash
ssh deploy@YOUR_DROPLET_IP
cd /opt/myapp
git pull
docker build -t myapp .
sudo systemctl restart myapp
sudo systemctl status myapp
```

---

## Useful commands

```bash
docker logs myapp -f             # tail live app logs
sudo journalctl -u myapp -f      # systemd-level logs (start/stop events)
sudo systemctl stop myapp        # stop the app
sudo systemctl restart myapp     # restart after changes
docker images                    # list built images on the server
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
├── main.tf                   # The infrastructure definition: droplet, firewall, SSH key, DNS
├── variables.tf              # Declares all input variables and their types/defaults
├── outputs.tf                # What Terraform prints after apply (IP address, app URL)
├── user_data.sh              # Bootstrap script that runs once on first boot
├── terraform.tfvars.example  # A safe template showing what values are needed
├── terraform.tfvars          # Your actual secret values: never commit this
└── .gitignore                # Excludes tfvars, state files, and the .terraform directory
```

- **`main.tf`** is the core. It describes what resources to create on DigitalOcean: the droplet, the firewall rules, the SSH key, and the domain with its DNS records. Terraform reads this and figures out what API calls to make. The DNS records reference the droplet's IP, so whenever the droplet is recreated, DNS follows it automatically.
- **`variables.tf`** lists every input the scripts accept (token, repo URL, port, etc.) without storing any values. It's the contract: `main.tf` references these, and you supply the actual values in `terraform.tfvars`.
- **`outputs.tf`** tells Terraform what to print when provisioning is done: in this case the droplet's IP address and the app's `https://` URL so you don't have to look them up manually.
- **`user_data.sh`** is a shell script that DigitalOcean runs automatically on the droplet the first time it boots. It handles everything in the manual guide: installing software, creating users, hardening SSH, starting the app as a service, and setting up Caddy for HTTPS. Terraform fills in its `${...}` placeholders (repo URL, port, password, domain) with `templatefile` before sending it to DigitalOcean. Because it only runs on first boot, any change to it (or to those variables) makes Terraform destroy and recreate the droplet.
- **`terraform.tfvars.example`** is a committed template that shows what variables need values. It contains no real secrets: just placeholders. Copy it to `terraform.tfvars` and fill it in.
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

Terraform automates everything in the manual guide except one step: verifying that your new `deploy` user login works before closing the root session. Since Terraform provisions the SSH key via the DigitalOcean API, you can be confident the key is correctly placed, but you should still SSH in as `deploy` after `apply` completes to confirm before relying on the server.

The bootstrap script (`user_data.sh`) runs once on first boot and handles:
- System updates
- UFW firewall setup
- Installing git and Docker
- Creating the `deploy` sudo user and copying your SSH key to them
- Disabling root SSH login and password authentication
- Cloning the repo and building the Docker image
- Starting the app as a systemd service running as `deploy`, published on `127.0.0.1` only
- Installing Caddy and configuring it to serve the domain over HTTPS

Terraform itself handles the Cloud Firewall (22, 80 and 443 only) and the DNS records. Buying the domain and pointing its nameservers to DigitalOcean (Step 16) is the one part you do by hand at the registrar.

### Generating a DigitalOcean API token

Go to the DigitalOcean dashboard → API → Generate New Token → choose **Custom Scopes**.

Select the following scopes:

| Resource | Permissions |
|---|---|
| `droplet` | Create, Read, Update, Delete |
| `firewall` | Create, Read, Update, Delete |
| `ssh_key` | Create, Read, Update, Delete |
| `domain` | Create, Read, Update, Delete |
| `project` | Create, Read, Update, Delete |
| `regions` | Read |
| `sizes` | Read |
| `image` | Read |
| `actions` | Read |
| `snapshot` | Read |
| `vpc` | Read |

The last four (`image`, `actions`, `snapshot`, `vpc`) are dependencies that DigitalOcean requires alongside the droplet scope: Terraform needs them under the hood even though you're not creating those resources directly. Select nothing else.

Copy the generated token immediately: DigitalOcean only shows it once.

### Setup

```bash
# 1. Copy and fill in your credentials
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in all values. The required ones:

| Variable | Description |
|---|---|
| `do_token` | DigitalOcean API token |
| `repo_url` | HTTPS URL of your GitHub repo (must contain a Dockerfile) |
| `deploy_password` | Password for the `deploy` user (used for sudo) |
| `app_port` | Port your app listens on inside the container |
| `domain_name` | Your domain without `www` (e.g. `example.com`), with nameservers already pointed to DigitalOcean (Step 16) |

The repo must be **public**: the droplet clones it over HTTPS without credentials, and for a private (or misspelled) repo GitHub asks for a username, which fails the unattended boot script with `could not read Username for 'https://github.com'`.

### Moving an existing domain into Terraform (one-time)

Skip this if the domain is not yet in your DigitalOcean account: `terraform apply` creates it. If you already added it in the dashboard (Step 17), Terraform does not know it exists and `apply` fails trying to create it again. Import it, and its two A records, into Terraform's state first:

```bash
terraform init
terraform import digitalocean_domain.main YOUR_DOMAIN

# Find the IDs of the @ and www A records
curl -s -H "Authorization: Bearer YOUR_DO_TOKEN" \
    "https://api.digitalocean.com/v2/domains/YOUR_DOMAIN/records?type=A"

terraform import digitalocean_record.root YOUR_DOMAIN,ID_OF_THE_@_RECORD
terraform import digitalocean_record.www YOUR_DOMAIN,ID_OF_THE_WWW_RECORD
```

In the `curl` output, each record has an `"id"` and a `"name"` (`"@"` or `"www"`). Import only changes Terraform's state file: nothing on DigitalOcean is modified. Afterwards, `terraform plan` shows how the live setup differs from the code.

### Apply

```bash
# 2. Initialize (downloads the DigitalOcean provider)
terraform init

# 3. Preview what will be created
terraform plan

# 4. Create the droplet
terraform apply
```

After `apply`, Terraform prints the droplet IP and app URL. The bootstrap script runs in the background: wait about 3 to 5 minutes for it to complete before testing. If the droplet was recreated, its IP changed: Terraform updates the DNS records, but caches across the internet may serve the old IP for a while.

### Verify

```bash
# Confirm you can log in as deploy (not root)
ssh deploy@YOUR_DROPLET_IP

# On the droplet: did the bootstrap script finish without errors?
cloud-init status --long
sudo tail -n 40 /var/log/cloud-init-output.log   # the error is usually at the bottom

# On the droplet: is the app running?
curl http://127.0.0.1:YOUR_APP_PORT
```

Then open `https://YOUR_DOMAIN` in a browser.

The boot script stops at the first failing command (`set -euo pipefail`), so everything after a failure is skipped. The rendered script, with all variables filled in, is at `/var/lib/cloud/instance/user-data.txt`. It is readable by root only because it contains `deploy_password` in plain text (which is also stored in `terraform.tfstate`).

### Tear down

```bash
terraform destroy
```

---

## Common issues

| Problem | Fix |
|---|---|
| Site isn't reachable | Check `dig +short YOUR_DOMAIN` returns the droplet IP, ports 80/443 are open in both firewalls, and `sudo journalctl -u caddy -n 50` |
| Browser fails on `http://YOUR_DOMAIN:8000` | Expected: the app port is private, and `.dev`/`.app` domains are HTTPS-only in browsers. Use `https://YOUR_DOMAIN` |
| `/opt/myapp` missing on the droplet | The boot script failed before cloning: check `/var/log/cloud-init-output.log` |
| `could not read Username for 'https://github.com'` | The repo is private or `repo_url` is wrong: see [Setup](#setup) |
| `terraform apply` fails creating the domain | It already exists in DigitalOcean: [import it](#moving-an-existing-domain-into-terraform-one-time) |
| Container exits immediately | `docker logs myapp` to see the error from inside the container |
| `docker build` fails | Confirm a `Dockerfile` exists in the repo root and the build succeeds locally first |
| Port already in use | `sudo fuser -k YOUR_APP_PORT/tcp` |
| Updated code not showing | `git pull && docker build -t myapp . && sudo systemctl restart myapp` |
| Service fails to start | `sudo journalctl -u myapp -n 50` to see systemd-level errors |
