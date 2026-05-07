variable "project_name" {
  description = "Short project identifier; used as the leading path segment in the secret name."
  type        = string
}

variable "env" {
  description = "Environment name (dev | stage | prod)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used in tags / display names."
  type        = string
}

variable "common_tags" {
  description = "Tags applied to every secret."
  type        = map(string)
  default     = {}
}

variable "secret_keys" {
  description = "Application secret keys to provision (e.g. DATABASE_PASSWORD)."
  type        = list(string)
  default     = []
}

variable "recovery_window_in_days" {
  description = "Number of days AWS retains the secret after delete (0 = immediate)."
  type        = number
  default     = 0
}
