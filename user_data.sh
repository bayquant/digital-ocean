#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Step 1 — Update system packages
# -----------------------------------------------------------------------------
apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# -----------------------------------------------------------------------------
# Step 2 — Set up UFW firewall
# Allow SSH before enabling — enabling first would sever this connection
# -----------------------------------------------------------------------------
ufw allow OpenSSH
ufw --force enable

# -----------------------------------------------------------------------------
# Step 3 — Install git
# -----------------------------------------------------------------------------
apt-get install -y git

# -----------------------------------------------------------------------------
# Step 4 — Install uv (Python toolchain)
# Installs to /root/.local/bin/uv — referenced by full path in later steps
# -----------------------------------------------------------------------------
curl -LsSf https://astral.sh/uv/install.sh | sh

# -----------------------------------------------------------------------------
# Step 5 — Create the deploy user with sudo privileges
# deploy is the human operator account — it can run privileged commands
# explicitly via sudo, but is not root
# -----------------------------------------------------------------------------
adduser --disabled-password --gecos "" deploy
echo "deploy:${deploy_password}" | chpasswd
usermod -aG sudo deploy

# -----------------------------------------------------------------------------
# Step 6 — Copy SSH authorized keys to the deploy user
# The droplet was provisioned with root's SSH key via the DigitalOcean API.
# This copies it so the same key works for the deploy user.
# Permissions must be strict — SSH refuses keys that are too open.
# -----------------------------------------------------------------------------
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

# -----------------------------------------------------------------------------
# Step 7 — Disable root SSH login and password authentication
# PermitRootLogin no: removes root as an SSH target entirely
# PasswordAuthentication no: only key-based login is accepted,
# making brute-force attacks impossible
# Ubuntu 22.04 may have a cloud-init override file that re-enables passwords —
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
# Step 8 — Create a dedicated system user to run the app
# No home directory, no login shell — this account cannot be used
# interactively, limiting what an attacker can do if the app is compromised
# -----------------------------------------------------------------------------
useradd --system --no-create-home --shell /usr/sbin/nologin appuser

# -----------------------------------------------------------------------------
# Step 9 — Clone the repository and assign ownership to appuser
# /opt is the conventional location for third-party apps on Linux
# -----------------------------------------------------------------------------
git clone ${repo_url} /opt/myapp
chown -R appuser:appuser /opt/myapp

# -----------------------------------------------------------------------------
# Step 10 — Create virtual environment and install dependencies as appuser
# Running as appuser ensures the venv is owned by the app process,
# not root — consistent with least privilege
# -----------------------------------------------------------------------------
sudo -u appuser bash -c "
    cd /opt/myapp
    /root/.local/bin/uv venv
    /opt/myapp/.venv/bin/pip install -r requirements.txt
"

# -----------------------------------------------------------------------------
# Step 11 — Open the app port in UFW
# Done after enabling UFW so the rule is added to an active firewall
# -----------------------------------------------------------------------------
ufw allow ${app_port}

# -----------------------------------------------------------------------------
# Step 12 — Create systemd service
# Runs as appuser with additional sandboxing:
#   NoNewPrivileges: prevents the process from escalating its own privileges
#   PrivateTmp: gives the process an isolated /tmp
# -----------------------------------------------------------------------------
cat > /etc/systemd/system/myapp.service << 'SYSTEMD_EOF'
[Unit]
Description=My app
After=network.target

[Service]
User=appuser
Group=appuser
WorkingDirectory=/opt/myapp
ExecStart=/opt/myapp/.venv/bin/${start_command}
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

# -----------------------------------------------------------------------------
# Step 13 — Enable and start the service
# enable: starts automatically on every boot
# start: starts it right now without rebooting
# -----------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable myapp
systemctl start myapp
