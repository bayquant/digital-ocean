# Hosting Web Apps on a DigitalOcean Droplet

These steps assume a fresh Ubuntu droplet. They are split into three phases: hardening the server, preparing it to host apps (Docker and Caddy), then deploying an app on a domain over HTTPS. Phases 1 and 2 are done once per droplet. Phase 3 is repeated for each app, and never touches the host setup again. Do not skip or reorder the hardening steps: some mistakes (like enabling a firewall before allowing SSH) will permanently lock you out.

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
│                        │ 127.0.0.1:PORT         │
│                        ▼ loopback only          │
│              ┌───────────────────┐              │
│              │ app container     │              │
│              │ /opt/apps/NAME    │              │
│              └───────────────────┘              │
│                                                 │
└─────────────────────────────────────────────────┘
```

Only ports 22, 80 and 443 are reachable from the internet. The apps themselves are never exposed directly: Caddy receives every request, handles HTTPS, and forwards it to the right app over the droplet's internal loopback connection. Each app is its own container with its own port, and registers its own domain with Caddy when it is deployed. [How traffic reaches the app](#how-traffic-reaches-the-app) explains each layer.

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

## Phase 2: Prepare the host for apps (one-time setup)

From here, SSH in as `deploy` and prefix privileged commands with `sudo`. Nothing in this phase is specific to one app: afterwards the droplet can host any number of Docker apps, each deployed in Phase 3.

### Step 8: Install Git

```bash
sudo apt install -y git
git --version   # confirm it installed
```

Git is not always present on a minimal droplet image. It is handy for working on the droplet directly. The deploy flow in Phase 3 sends code over SSH and does not need it.

### Step 9: Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker deploy
```

Docker packages your app and all its dependencies into a self-contained image that runs the same way on any machine. The official convenience script (`get.docker.com`) installs Docker's latest stable release from Docker's own package repository, including the `docker compose` plugin that Phase 3 uses.

`usermod -aG docker deploy` adds `deploy` to the `docker` group. By default, only root can run Docker commands. The `docker` group is a way to grant that ability to a normal user without giving them full sudo. This matters because deploys run `docker compose` as `deploy`.

### Step 10: Open HTTP and HTTPS in the firewall

```bash
sudo ufw allow 80
sudo ufw allow 443
sudo ufw status
```

These are the ports Caddy will listen on: 443 serves your sites over HTTPS, and 80 is used by Let's Encrypt to verify you control each domain and to redirect plain HTTP visitors to HTTPS. This must be done after enabling UFW (Step 3) so the rules are added to an already-active firewall.

Do **not** open any app's port (e.g. 8000). Apps only accept connections from the droplet itself (see Step 14), and Caddy is the only thing that talks to them.

### Step 11: Install Caddy

```bash
CADDY_VERSION=2.11.7
curl -fsSLO "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_$(dpkg --print-architecture).deb"
sudo apt install -y "./caddy_${CADDY_VERSION}_linux_$(dpkg --print-architecture).deb"
rm "caddy_${CADDY_VERSION}_linux_$(dpkg --print-architecture).deb"
```

Caddy is a web server used here as a **reverse proxy**: it stands in front of the apps, receives every request on the standard web ports, forwards it to the right app, and sends the reply back. It also handles HTTPS: it obtains a free certificate from Let's Encrypt (the "SSL certificate" that proves the server really is your domain) and renews it before it expires, with no configuration beyond naming the domain. Ubuntu 22.04 does not ship Caddy, so these commands install the `.deb` that Caddy publishes on its GitHub releases page (it includes the systemd service and a `caddy` user, exactly like the apt package). The version is pinned: check the [releases page](https://github.com/caddyserver/caddy/releases) for a newer one when you rebuild. Caddy's own apt repository is deliberately not used: it has returned `402 Payment Required` (a download quota on the hosting service's side), which breaks `apt update` for the whole machine.

Caddy is not a load balancer in this setup: a load balancer spreads requests across several copies of an app, while here each domain goes to the one container that serves it.

### Step 12: Let each app add its own site to Caddy

```bash
sudo mkdir -p /etc/caddy/conf.d
sudo chown deploy:deploy /etc/caddy/conf.d
echo 'import /etc/caddy/conf.d/*.caddy' | sudo tee /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

The whole main Caddyfile becomes one line. `import` means "load every file in that folder whose name ends in `.caddy`, as if its contents were pasted here". Each app drops its own file in `conf.d` when it is deployed (Step 14), so apps never edit a shared file and cannot break each other's configuration.

- The folder is owned by `deploy`, so writing a snippet needs no `sudo`.
- With no snippets yet, Caddy logs a warning (`No files matching import glob pattern`) and serves nothing. That is the correct state at this point.
- If a snippet has a syntax error, `reload` fails and Caddy keeps running the old working configuration.

### Step 13: Create the apps directory and allow Caddy reloads

```bash
sudo mkdir -p /opt/apps
sudo chown deploy:deploy /opt/apps

echo 'deploy ALL=(root) NOPASSWD: /usr/bin/systemctl reload caddy' | sudo tee /etc/sudoers.d/deploy-caddy
sudo chmod 440 /etc/sudoers.d/deploy-caddy
sudo visudo -cf /etc/sudoers.d/deploy-caddy
```

`/opt` is the conventional location for third-party applications on Linux, and each app gets its own subdirectory: `/opt/apps/YOUR_APP`. The directory is owned by `deploy` because `deploy` is the one that places code there and manages the containers.

A deploy runs non-interactively over SSH, so a `sudo` password prompt would hang it. The sudoers rule lets `deploy` run exactly one command without a password: reloading Caddy. Everything else still asks for the password. `visudo -cf` checks the syntax, because a typo in a sudoers file can break `sudo` entirely.

---

## Phase 3: Deploy an app (repeat for each app)

The host is ready. Every app brings its own deployment files, and the host setup above is never edited per app. Steps 16 to 18 (domain, DNS, Cloud Firewall) are done once per domain: if you do not have one yet, do them before filling in the app's Caddy snippet. By convention each app repo has a `deploy/` folder:

```
YOUR_APP/
  deploy/
    compose.yaml      # how the app runs
    YOUR_APP.caddy    # which domain(s) Caddy serves it on
    deploy.sh         # ships the code and runs the steps below
```

### Step 14: Write the app's deploy files

`deploy/compose.yaml` describes how the app runs:

```yaml
name: YOUR_APP

services:
  YOUR_APP:
    container_name: YOUR_APP
    build: ..
    ports:
      - "127.0.0.1:YOUR_APP_PORT:YOUR_APP_PORT"
    restart: unless-stopped
```

`deploy/YOUR_APP.caddy` is the site block Caddy loads from `conf.d`:

```
YOUR_DOMAIN, www.YOUR_DOMAIN {
    reverse_proxy 127.0.0.1:YOUR_APP_PORT
}
```

- `build: ..` builds the image from the `Dockerfile` in the repo root (the compose file sits one level down, in `deploy/`). It installs your app's dependencies inside the image so the server needs no language runtime or packages of its own.
- `127.0.0.1:YOUR_APP_PORT:YOUR_APP_PORT` forwards the droplet's port into the container, but only on the loopback address `127.0.0.1`, so only programs on the droplet (Caddy) can connect. Without the `127.0.0.1:` prefix, Docker publishes the port on `0.0.0.0` (every network connection), and its own firewall rules bypass UFW: the app would be reachable from the internet even though UFW never allowed the port.
- `restart: unless-stopped` brings the container back after a crash or a reboot. Docker itself starts at boot, so no systemd unit is needed per app. Do not use `screen` or `nohup`: they don't survive reboots and don't restart the app on crash.
- Give every app on the droplet its own port (8000, 8001, ...).
- The first line of the snippet lists the names Caddy answers for. Naming real domains is what makes Caddy fetch the HTTPS certificate.
- `reverse_proxy 127.0.0.1:YOUR_APP_PORT` forwards every request to the app on the loopback address. Use `127.0.0.1`, not `localhost`: `localhost` can resolve to the IPv6 loopback `::1`, where Docker is not listening (the port above is published on IPv4 only).

### Step 15: Deploy and verify

From the app's repo on your laptop, send the committed code to the droplet and start it:

```bash
git archive --format=tar HEAD | ssh deploy@YOUR_DROPLET_IP "rm -rf /opt/apps/YOUR_APP && mkdir -p /opt/apps/YOUR_APP && tar -x -C /opt/apps/YOUR_APP"

ssh deploy@YOUR_DROPLET_IP
cd /opt/apps/YOUR_APP
docker compose -f deploy/compose.yaml up -d --build
cp deploy/YOUR_APP.caddy /etc/caddy/conf.d/YOUR_APP.caddy
sudo systemctl reload caddy
curl http://127.0.0.1:YOUR_APP_PORT
```

`git archive` runs on your laptop and packs the files of the latest commit (`HEAD`) into a tarball, which the droplet unpacks. Uncommitted changes are not deployed. The droplet needs no access to your repository, so it works for private repos too.

If the app responds on the loopback address, it is up. It is not reachable from outside until DNS points at the droplet (Step 17). The `deploy.sh` in each app repo performs exactly the commands above in one go (see [Adding an app](#adding-an-app)).

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

In the DigitalOcean dashboard: **Networking** → **Domains** → add `YOUR_DOMAIN` to your project, then create two **A** records directing to your droplet (one domain can serve several apps: add a record per extra subdomain):

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

UFW (Step 10) and the Cloud Firewall are separate layers, and traffic must pass both. If you deploy with Terraform, change the firewall in `main.tf` instead: Terraform reverts manual dashboard changes on the next `apply`.

### Step 19: Verify HTTPS

Open `https://YOUR_DOMAIN` in a browser. The first visit can take a few seconds while Caddy obtains the certificate. If it fails:

```bash
sudo journalctl -u caddy -n 50   # Caddy's logs, including certificate errors
```

The most common cause is DNS not pointing at the droplet yet (Step 17) or port 80/443 blocked by one of the firewalls (Steps 10 and 18).

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

Publishing a port (`docker run -p`, or `ports:` in a compose file) writes its own low-level firewall rules, and they are checked before UFW's. A port published on `0.0.0.0` is therefore reachable from the internet even if `ufw status` shows it closed. Two defenses apply here: each app is published on `127.0.0.1` only (Step 14), and the Cloud Firewall, which sits outside the droplet and is unaffected by Docker, does not allow the app's port.

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
- **On the droplet, the port is published on `127.0.0.1`** (`127.0.0.1:8000:8000` in `compose.yaml`). This is where access is restricted. Rule of thumb: inside a container, always listen on `0.0.0.0`; decide who can reach it with the published port.
- **Firewall rules for 80 and 443 use `0.0.0.0/0`**, because the site is public. A rule allowing only `127.0.0.1` would match nothing: loopback traffic never crosses the Cloud Firewall.
- **SSH (22) could be narrowed** to your own IP (e.g. `["203.0.113.5/32"]`), at the cost of a lockout whenever your home IP changes. Key-only login (Step 6) already makes brute-forcing it infeasible, so it is left open to all.

### Why `.dev` domains only work over HTTPS

Browsers ship with a built-in **HSTS preload list** of domains that must only ever be loaded over HTTPS. Google, which runs the `.dev` ending, preloaded the entire ending (as with `.app` and `.page`), so browsers silently rewrite `http://` to `https://` for every `.dev` site. Without Caddy (or another HTTPS setup) such a site cannot be opened in a browser at all, even on a plain-HTTP port like `:8000`. Tools like `curl` do not use the preload list, so `curl http://...` still works for testing.

---

## Updating an app

Commit your change, then run the app's deploy script from its repo on your laptop:

```bash
deploy/deploy.sh                       # defaults to deploy@YOUR_DOMAIN
deploy/deploy.sh deploy@YOUR_DROPLET_IP
```

It ships the committed code, rebuilds the image, restarts the container, re-registers the Caddy snippet and waits for the app's health check. Only `HEAD` is deployed, so uncommitted changes are left out (the script warns you).

---

## Useful commands

```bash
docker ps                                                            # running containers
docker logs YOUR_APP -f                                              # tail an app's live logs
docker compose -f /opt/apps/YOUR_APP/deploy/compose.yaml restart     # restart an app
docker compose -f /opt/apps/YOUR_APP/deploy/compose.yaml down        # stop and remove an app
ls /etc/caddy/conf.d                                                 # which sites Caddy serves
sudo journalctl -u caddy -f                                          # Caddy's logs
docker images                                                        # list built images on the server
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
├── user_data.sh              # Host bootstrap script that runs once on first boot
├── terraform.tfvars.example  # A safe template showing what values are needed
├── terraform.tfvars          # Your actual secret values: never commit this
└── .gitignore                # Excludes tfvars, state files, and the .terraform directory
```

- **`main.tf`** is the core. It describes what resources to create on DigitalOcean: the droplet, the firewall rules, the SSH key, and the domain with its DNS records. Terraform reads this and figures out what API calls to make. The DNS records reference the droplet's IP, so whenever the droplet is recreated, DNS follows it automatically.
- **`variables.tf`** lists every input the scripts accept (token, host name, region, domain, etc.) without storing any values. It's the contract: `main.tf` references these, and you supply the actual values in `terraform.tfvars`.
- **`outputs.tf`** tells Terraform what to print when provisioning is done: in this case the droplet's IP address, so you don't have to look it up manually.
- **`user_data.sh`** is a shell script that DigitalOcean runs automatically on the droplet the first time it boots. It handles Phases 1 and 2 of the manual guide: hardening the server and installing Docker and Caddy. It knows nothing about any app: apps are deployed afterwards from their own repos (see [Adding an app](#adding-an-app)). Terraform fills in its one `${...}` placeholder (the `deploy` password) with `templatefile` before sending it to DigitalOcean. Because it only runs on first boot, any change to it (or to that variable) makes Terraform destroy and recreate the droplet. Keeping app details out of it is what keeps it stable.
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

Terraform automates Phases 1 and 2 of the manual guide, except one step: verifying that your new `deploy` user login works before closing the root session. Phase 3 (deploying an app) is done per app, from the app's own repo. Since Terraform provisions the SSH key via the DigitalOcean API, you can be confident the key is correctly placed, but you should still SSH in as `deploy` after `apply` completes to confirm before relying on the server.

The bootstrap script (`user_data.sh`) runs once on first boot and handles:
- System updates
- UFW firewall setup
- Installing git and Docker
- Creating the `deploy` sudo user and copying your SSH key to them
- Disabling root SSH login and password authentication
- Installing Caddy, with a main Caddyfile that only imports `/etc/caddy/conf.d/*.caddy`
- Letting `deploy` write Caddy snippets and reload Caddy without a password (nothing else)
- Creating `/opt/apps`, where each app is deployed

Terraform itself handles the Cloud Firewall (22, 80 and 443 only) and the DNS records for `domain_name`. Buying the domain and pointing its nameservers to DigitalOcean (Step 16) is the one part you do by hand at the registrar.

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
| `deploy_password` | Password for the `deploy` user (used for sudo) |
| `domain_name` | Your domain without `www` (e.g. `example.com`), with nameservers already pointed to DigitalOcean (Step 16). Terraform creates its `@` and `www` A records |

The optional ones (`host_name`, `region`, `size`, `ssh_public_key_path`, `project_name`) have defaults in `variables.tf`. No app details are needed here: the droplet starts with no app on it.

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

After `apply`, Terraform prints the droplet IP. The bootstrap script runs in the background: wait about 3 to 5 minutes for it to complete before testing. If the droplet was recreated, its IP changed: Terraform updates the DNS records, but caches across the internet may serve the old IP for a while, so deploy to the IP directly (`deploy/deploy.sh deploy@YOUR_DROPLET_IP`). SSH will also warn that the host key changed, because it is a new machine: clear the old entry with `ssh-keygen -R YOUR_DROPLET_IP` (and `ssh-keygen -R YOUR_DOMAIN`).

The droplet has no app on it yet: deploy one as described in [Adding an app](#adding-an-app).

### Verify

```bash
# Confirm you can log in as deploy (not root)
ssh deploy@YOUR_DROPLET_IP

# On the droplet: wait for the bootstrap script, then check it finished without errors
# (until it reaches Step 4, the login above fails with "Permission denied (publickey)": retry in a minute)
cloud-init status --wait    # expect "status: done"
cloud-init status --long
sudo tail -n 40 /var/log/cloud-init-output.log   # the error is usually at the bottom

# On the droplet: are Docker and Caddy up, and is the apps directory there?
docker --version
systemctl is-active caddy
ls /opt/apps /etc/caddy/conf.d
```

An empty `/opt/apps` and `conf.d` is correct at this point.

The boot script stops at the first failing command (`set -euo pipefail`), so everything after a failure is skipped. The rendered script, with all variables filled in, is at `/var/lib/cloud/instance/user-data.txt`. It is readable by root only because it contains `deploy_password` in plain text (which is also stored in `terraform.tfstate`).

### Adding an app

The host knows nothing about your apps, so adding one never touches this repo's code (apart from a DNS record for a new subdomain, below). Copy the `deploy/` folder of an existing app, such as the `website` repo's, into the new app's repo and change the names:

1. **`compose.yaml`**: the app name, and a port that no other app on the droplet uses (8000, 8001, ...).
2. **`YOUR_APP.caddy`**: the domain(s) the app answers on, and the same port.
3. **`deploy.sh`**: the `app` and `port` variables at the top.
4. **DNS**: the `@` and `www` records of `domain_name` already point at the droplet. For another subdomain, add a record to `main.tf`:

   ```hcl
   resource "digitalocean_record" "blog" {
     domain = digitalocean_domain.main.id
     type   = "A"
     name   = "blog"
     value  = digitalocean_droplet.host.ipv4_address
   }
   ```

5. **Deploy**: commit, then run `deploy/deploy.sh` from the app's repo.

The app's `.caddy` file is what names its domains: `domain_name` in Terraform only controls DNS. Removing an app is `docker compose down` and deleting its file from `/etc/caddy/conf.d`, followed by `sudo systemctl reload caddy`.

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
| `/opt/apps` missing on the droplet | The boot script failed before the last step: check `/var/log/cloud-init-output.log` |
| `terraform apply` fails creating the domain | It already exists in DigitalOcean: [import it](#moving-an-existing-domain-into-terraform-one-time) |
| Container exits immediately | `docker logs YOUR_APP` to see the error from inside the container |
| `docker build` fails | Confirm a `Dockerfile` exists in the repo root and the build succeeds locally first |
| Port already in use | `sudo fuser -k YOUR_APP_PORT/tcp` |
| Updated code not showing | Commit first: a deploy ships `HEAD` only. Then rerun `deploy/deploy.sh` |
| `deploy.sh` hangs or asks for a password at the Caddy reload | The sudoers rule is missing or has a typo: `sudo -l` as `deploy` lists what it may run without a password (Step 13) |
| Caddy reload fails | A snippet in `/etc/caddy/conf.d` has a syntax error: `sudo journalctl -u caddy -n 50`. The previous config keeps running meanwhile |
| SSH says `REMOTE HOST IDENTIFICATION HAS CHANGED` | The droplet was recreated and is a new machine: `ssh-keygen -R YOUR_DROPLET_IP` |
