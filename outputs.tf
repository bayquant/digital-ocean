output "droplet_ip" {
  description = "Public IPv4 address of the droplet"
  value       = digitalocean_droplet.host.ipv4_address
}
