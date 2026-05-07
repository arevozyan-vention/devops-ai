variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "sku" {
  type    = string
  default = "standard"
}

variable "purge_protection" {
  type    = bool
  default = false
}

variable "soft_delete_days" {
  type    = number
  default = 7
}

variable "secret_names" {
  type        = list(string)
  description = "Names of placeholder secrets to create (operator populates values later)."
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
