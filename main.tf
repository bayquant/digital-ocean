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

# Firewall: only allow SSH, HTTP and HTTPS
# App ports are not opened: apps only listen on the droplet's loopback,
# and Caddy forwards public traffic to them
resource "digitalocean_firewall" "host" {
  name = "${var.host_name}-firewall"

  droplet_ids = [digitalocean_droplet.host.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
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

# Project: groups resources together in the DO dashboard
resource "digitalocean_project" "main" {
  name       = var.project_name
  is_default = true
}

resource "digitalocean_project_resources" "main" {
  project = digitalocean_project.main.id
  resources = [
    digitalocean_droplet.host.urn,
    digitalocean_domain.main.urn,
  ]
}

# The droplet: a host for any number of apps, each deployed from its own repo
resource "digitalocean_droplet" "host" {
  name     = var.host_name
  region   = var.region
  size     = var.size
  image    = "ubuntu-22-04-x64"
  ssh_keys = [digitalocean_ssh_key.default.fingerprint]

  # Runs once on first boot: hardens the host and installs Docker and Caddy.
  # It knows nothing about apps, so it should rarely change: any change here
  # makes Terraform destroy and recreate the droplet
  user_data = templatefile("${path.module}/user_data.sh", {
    deploy_password = var.deploy_password
  })
}

# DNS: DigitalOcean answers for the domain because the registrar's nameservers
# point to ns1/ns2/ns3.digitalocean.com
resource "digitalocean_domain" "main" {
  name = var.domain_name
}

# Both records reference the droplet's IP, so recreating the droplet updates
# DNS automatically
resource "digitalocean_record" "root" {
  domain = digitalocean_domain.main.id
  type   = "A"
  name   = "@"
  value  = digitalocean_droplet.host.ipv4_address
}

resource "digitalocean_record" "www" {
  domain = digitalocean_domain.main.id
  type   = "A"
  name   = "www"
  value  = digitalocean_droplet.host.ipv4_address
}

# These resources were labelled "app" when the droplet ran a single app. The
# moved blocks carry the existing state over to the new labels; once applied
# they can be deleted
moved {
  from = digitalocean_droplet.app
  to   = digitalocean_droplet.host
}

moved {
  from = digitalocean_firewall.app
  to   = digitalocean_firewall.host
}
