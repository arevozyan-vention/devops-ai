variable "name" {
  description = "Security group name."
  type        = string
}

variable "vpc_id" {
  description = "VPC the SG lives in."
  type        = string
}

variable "ingress_cidr_blocks" {
  description = "CIDR blocks allowed to reach the database on the listed port."
  type        = list(string)
  default     = []
}

variable "port" {
  description = "Database port."
  type        = number
  default     = 5432
}

variable "common_tags" {
  description = "Tags to apply."
  type        = map(string)
  default     = {}
}
