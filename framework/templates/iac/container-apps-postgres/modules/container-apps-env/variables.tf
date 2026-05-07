variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "infrastructure_subnet_id" {
  type        = string
  description = "Subnet delegated to Microsoft.App/environments (>= /23)."
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
