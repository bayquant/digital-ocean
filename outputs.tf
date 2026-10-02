output "droplet_ip" {
  description = "Public IPv4 address of the droplet"
  value       = digitalocean_droplet.app.ipv4_address
}

output "app_url" {
  description = "URL to reach the running app"
  value       = "https://${var.domain_name}"
}
