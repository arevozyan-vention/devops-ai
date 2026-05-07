variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "acr_id" {
  type        = string
  description = "Resource ID of the ACR to grant AcrPull on. Empty string skips the role assignment."
  default     = ""
}

variable "key_vault_id" {
  type        = string
  description = "Resource ID of the Key Vault to grant Secrets User on. Empty string skips."
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
