#!/bin/bash
set -euo pipefail

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
# Uses Docker's official convenience script.
# Adds deploy to the docker group so the systemd service can run docker
# commands as deploy without needing sudo.
# -----------------------------------------------------------------------------
curl -fsSL https://get.docker.com | sh
usermod -aG docker deploy

# -----------------------------------------------------------------------------
# Step 8: Clone the repository
# Owned by deploy since deploy will build and manage the container
# -----------------------------------------------------------------------------
git clone ${repo_url} /opt/myapp
chown -R deploy:deploy /opt/myapp

# -----------------------------------------------------------------------------
# Step 9: Build the Docker image
# Reads the Dockerfile in the repo and produces a local image named myapp
# -----------------------------------------------------------------------------
docker build -t myapp /opt/myapp

# -----------------------------------------------------------------------------
# Step 10: Open HTTP and HTTPS in UFW
# Done after enabling UFW so the rules are added to an active firewall.
# Caddy (Step 13) listens on both: 80 for Let's Encrypt's domain check and the
# redirect to HTTPS, 443 for the site itself. The app port is not opened.
# -----------------------------------------------------------------------------
ufw allow 80
ufw allow 443

# -----------------------------------------------------------------------------
# Step 11: Create systemd service
# Runs as deploy (who is in the docker group).
# ExecStartPre cleans up any leftover container from a previous run:
# the leading - means systemd ignores failure if no container exists yet.
# Requires=docker.service ensures the Docker daemon is running first.
# -p 127.0.0.1:... publishes the port on the droplet's loopback only, so only
# programs on the droplet (Caddy) can reach the app. Docker writes its own
# firewall rules that bypass UFW, so binding to loopback is what actually
# keeps the port private.
# -----------------------------------------------------------------------------
cat > /etc/systemd/system/myapp.service << 'SYSTEMD_EOF'
[Unit]
Description=My app
After=network.target docker.service
Requires=docker.service

[Service]
User=deploy
Restart=on-failure
ExecStartPre=-/usr/bin/docker stop myapp
ExecStartPre=-/usr/bin/docker rm myapp
ExecStart=/usr/bin/docker run --name myapp -p 127.0.0.1:${app_port}:${app_port} myapp
ExecStop=/usr/bin/docker stop myapp

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

# -----------------------------------------------------------------------------
# Step 12: Enable and start the service
# enable: starts automatically on every boot
# start: starts it right now without rebooting
# -----------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable myapp
systemctl start myapp

# -----------------------------------------------------------------------------
# Step 13: Install Caddy and serve the app over HTTPS
# Caddy is a reverse proxy: it receives public traffic on 80/443 and forwards
# it to the app on the droplet's loopback. Naming the domains in the Caddyfile
# makes Caddy obtain and renew a Let's Encrypt certificate automatically.
# If DNS does not point at this droplet yet, Caddy keeps retrying on its own.
# Installed from Caddy's official apt repository (Ubuntu 22.04 has no package).
# -----------------------------------------------------------------------------
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

cat > /etc/caddy/Caddyfile << 'CADDY_EOF'
${domain_name}, www.${domain_name} {
    reverse_proxy 127.0.0.1:${app_port}
}
CADDY_EOF

systemctl reload caddy
