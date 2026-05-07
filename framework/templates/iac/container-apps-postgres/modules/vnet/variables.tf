variable "name_prefix" {
  type        = string
  description = "<project>-<env> prefix used for all resources."
}

variable "resource_group_name" {
  type        = string
  description = "Existing resource group to put VNet resources in."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "vnet_cidr" {
  type        = string
  description = "CIDR for the entire VNet."
}

variable "subnet_container_apps_cidr" {
  type        = string
  description = "CIDR for the Container Apps subnet (must be at least /23 for Consumption profile)."
}

variable "subnet_postgres_cidr" {
  type        = string
  description = "CIDR for the Postgres Flexible Server delegated subnet."
}

variable "tags" {
  type    = map(string)
  default = {}
}
