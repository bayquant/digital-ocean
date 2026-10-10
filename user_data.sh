#!/bin/bash
set -euo pipefail

# This script prepares the host only: it knows nothing about any app. Each app
# is deployed afterwards from its own repo into /opt/apps/<name> (see the
# README, "Adding an app").

# -----------------------------------------------------------------------------
# Step 1: Update system packages
# -----------------------------------------------------------------------------
apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# -----------------------------------------------------------------------------
# Step 2: Set up UFW firewall
# Allow SSH before enabling: enabling first would sever this connection
# -----------------------------------------------------------------------------
ufw allow OpenSSH
ufw --force enable

# -----------------------------------------------------------------------------
# Step 3: Install git
# Not used by the deploy flow itself (code arrives as a tarball over SSH), but
# kept for working on the droplet directly: cloning, pulling, debugging
# -----------------------------------------------------------------------------
apt-get install -y git

# -----------------------------------------------------------------------------
# Step 4: Create the deploy user with sudo privileges
# deploy is the human operator account: it can run privileged commands
# explicitly via sudo, but is not root
# -----------------------------------------------------------------------------
adduser --disabled-password --gecos "" deploy
echo "deploy:${deploy_password}" | chpasswd
usermod -aG sudo deploy

# -----------------------------------------------------------------------------
# Step 5: Copy SSH authorized keys to the deploy user
# The droplet was provisioned with root's SSH key via the DigitalOcean API.
# This copies it so the same key works for the deploy user.
# Permissions must be strict: SSH refuses keys that are too open.
# -----------------------------------------------------------------------------
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

# -----------------------------------------------------------------------------
# Step 6: Disable root SSH login and password authentication
# PermitRootLogin no: removes root as an SSH target entirely
# PasswordAuthentication no: only key-based login is accepted,
# making brute-force attacks impossible
# Ubuntu 22.04 may have a cloud-init override file that re-enables passwords:
# patch it too if present
# -----------------------------------------------------------------------------
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' \
        /etc/ssh/sshd_config.d/50-cloud-init.conf
fi

systemctl restart ssh

# -----------------------------------------------------------------------------
# Step 7: Install Docker
# Uses Docker's official convenience script, which also installs the
# `docker compose` plugin that each app's deploy uses.
# Adds deploy to the docker group so it can run docker commands without sudo.
# -----------------------------------------------------------------------------
curl -fsSL https://get.docker.com | sh
usermod -aG docker deploy

# -----------------------------------------------------------------------------
# Step 8: Open HTTP and HTTPS in UFW
# Done after enabling UFW so the rules are added to an active firewall.
# Caddy (Step 9) listens on both: 80 for Let's Encrypt's domain check and the
# redirect to HTTPS, 443 for the sites themselves. App ports are never opened:
# each app publishes on the droplet's loopback only.
# -----------------------------------------------------------------------------
ufw allow 80
ufw allow 443

# -----------------------------------------------------------------------------
# Step 9: Install Caddy
# Caddy is a reverse proxy: it receives public traffic on 80/443 and forwards
# it to the apps on the droplet's loopback. It obtains and renews Let's Encrypt
# certificates automatically for every domain named in a site block.
# Installed from Caddy's official apt repository (Ubuntu 22.04 has no package).
# -----------------------------------------------------------------------------
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

# -----------------------------------------------------------------------------
# Step 10: Let each app add its own site to Caddy
# The main Caddyfile only imports /etc/caddy/conf.d/*.caddy. An app's deploy
# drops a snippet there (owned by deploy, so no sudo to write it) and reloads
# Caddy. With no snippets yet, Caddy simply serves nothing.
# -----------------------------------------------------------------------------
mkdir -p /etc/caddy/conf.d
chown deploy:deploy /etc/caddy/conf.d

cat > /etc/caddy/Caddyfile << 'CADDY_EOF'
import /etc/caddy/conf.d/*.caddy
CADDY_EOF

systemctl reload caddy

# -----------------------------------------------------------------------------
# Step 11: Allow deploy to reload Caddy without a password
# A deploy runs non-interactively over SSH, so a sudo password prompt would
# hang it. The rule covers this one command only: everything else still
# needs the password. visudo -c checks the syntax so a typo cannot break sudo.
# -----------------------------------------------------------------------------
cat > /etc/sudoers.d/deploy-caddy << 'SUDOERS_EOF'
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl reload caddy
SUDOERS_EOF
chmod 440 /etc/sudoers.d/deploy-caddy
visudo -cf /etc/sudoers.d/deploy-caddy

# -----------------------------------------------------------------------------
# Step 12: Create the directory apps are deployed into
# One subdirectory per app: /opt/apps/<name>
# -----------------------------------------------------------------------------
mkdir -p /opt/apps
chown deploy:deploy /opt/apps
