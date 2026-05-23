output "droplet_ip" {
  description = "Public IPv4 address of the droplet"
  value       = digitalocean_droplet.app.ipv4_address
}

output "app_url" {
  description = "URL to reach the running app"
  value       = "http://${digitalocean_droplet.app.ipv4_address}:${var.app_port}"
}
