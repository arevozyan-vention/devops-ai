variable "name" {
  type        = string
  description = "Resource group name."
}

variable "location" {
  type        = string
  description = "Azure region (e.g. eastus, westeurope)."
}

variable "tags" {
  type    = map(string)
  default = {}
}
