variable "name_prefix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "capacity" {
  type        = number
  default     = 0 # C0 = 250 MB
  description = "Redis cache size unit (0..6 for Basic/Standard, see Azure SKU table)."
}

variable "family" {
  type    = string
  default = "C"
}

variable "sku" {
  type    = string
  default = "Basic"
}

variable "tags" {
  type    = map(string)
  default = {}
}
