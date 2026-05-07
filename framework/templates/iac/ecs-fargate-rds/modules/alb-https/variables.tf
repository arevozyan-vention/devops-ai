variable "alb_arn" {
  description = "ARN of the existing ALB to attach the HTTPS listener to"
  type        = string
}

variable "alb_dns_name" {
  description = "ALB public DNS — used as the cert's CN/SAN so browsers don't double-warn"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
