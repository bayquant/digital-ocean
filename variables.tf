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

variable "app_name" {
  description = "Name for the droplet and firewall"
  type        = string
  default     = "fastapi-app"
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

variable "app_port" {
  description = "Port the app listens on"
  type        = number
  default     = 8000
}

variable "repo_url" {
  description = "HTTPS URL of your GitHub repo to clone on the droplet"
  type        = string
}

variable "deploy_password" {
  description = "Password for the deploy user — needed for sudo on the droplet (never commit this)"
  type        = string
  sensitive   = true
}

variable "start_command" {
  description = "Command to start the app, relative to the venv bin directory (e.g. 'uvicorn main:app --host 0.0.0.0 --port 8000')"
  type        = string
}
