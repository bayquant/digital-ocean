terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# Upload your local SSH public key to DigitalOcean
resource "digitalocean_ssh_key" "default" {
  name       = "deployer"
  public_key = file(var.ssh_public_key_path)
}

# Firewall — only allow SSH and app port
resource "digitalocean_firewall" "app" {
  name = "${var.app_name}-firewall"

  droplet_ids = [digitalocean_droplet.app.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = tostring(var.app_port)
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# The droplet
resource "digitalocean_droplet" "app" {
  name     = var.app_name
  region   = var.region
  size     = var.size
  image    = "ubuntu-22-04-x64"
  ssh_keys = [digitalocean_ssh_key.default.fingerprint]

  # Runs once on first boot: installs uv, clones repo, starts app
  user_data = templatefile("${path.module}/user_data.sh", {
    repo_url        = var.repo_url
    app_port        = var.app_port
    deploy_password = var.deploy_password
  })
}
