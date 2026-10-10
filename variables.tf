variable "do_token" {
  description = "DigitalOcean API token (generate at DO dashboard → API)"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to your local SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "host_name" {
  description = "Name for the droplet and firewall"
  type        = string
  default     = "host"
}

variable "region" {
  description = "DigitalOcean region slug"
  type        = string
  default     = "nyc3"
}

variable "size" {
  description = "Droplet size slug"
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "deploy_password" {
  description = "Password for the deploy user: needed for sudo on the droplet (never commit this)"
  type        = string
  sensitive   = true
}

variable "domain_name" {
  description = "Domain whose DNS zone Terraform manages, without www (e.g. example.com); its @ and www records point at the droplet"
  type        = string
}

variable "project_name" {
  description = "DigitalOcean project to place the droplet in (created if it doesn't exist)"
  type        = string
  default     = "bay-quant"
}
