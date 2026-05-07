variable "name_prefix" {
  type = string
}

variable "suffix" {
  type        = string
  description = "Optional suffix to differentiate registries within the same project (e.g. \"frontend\")."
  default     = ""
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "sku" {
  type        = string
  default     = "Basic"
  description = "Basic | Standard | Premium. Premium adds geo-replication, retention policy, content trust."
}

variable "admin_enabled" {
  type        = bool
  default     = false
  description = "Enable the static admin password. Leave false; pull via managed identity."
}

variable "tags" {
  type    = map(string)
  default = {}
}
