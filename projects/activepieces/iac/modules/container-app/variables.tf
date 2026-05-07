variable "name_prefix" {
  type = string
}

variable "suffix" {
  type    = string
  default = ""
}

variable "container_app_environment_id" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "identity_id" {
  type        = string
  description = "Resource ID of the user-assigned managed identity to attach."
}

variable "acr_login_server" {
  type        = string
  description = "<acrname>.azurecr.io. The identity must have AcrPull on this registry."
}

variable "image" {
  type        = string
  description = "Initial image. Placeholder is fine; deploy-app updates via az cli."
  default     = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
}

variable "container_name" {
  type    = string
  default = "app"
}

variable "target_port" {
  type        = number
  description = "Container port the app listens on. ACA ingress maps :80/:443 → this."
}

variable "health_check_path" {
  type        = string
  description = "HTTP path used by liveness/readiness/startup probes. Empty disables probes."
  default     = "/"
}

variable "cpu" {
  type        = number
  description = "vCPU cores. 0.25 / 0.5 / 0.75 / 1.0 / 1.25 / 1.5 / 1.75 / 2.0 on Consumption."
}

variable "memory_gib" {
  type        = number
  description = "Memory in GiB. Must respect the cpu:memory ratio table for Consumption."
}

variable "min_replicas" {
  type    = number
  default = 1
}

variable "max_replicas" {
  type    = number
  default = 3
}

variable "env_vars" {
  type        = map(string)
  description = "Plain (non-secret) env vars."
  default     = {}
}

variable "kv_secret_uris" {
  type        = map(string)
  description = "Map of ENV_NAME → Key Vault versionless secret URI. Each is exposed as a secretRef and an env var of the same name."
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
