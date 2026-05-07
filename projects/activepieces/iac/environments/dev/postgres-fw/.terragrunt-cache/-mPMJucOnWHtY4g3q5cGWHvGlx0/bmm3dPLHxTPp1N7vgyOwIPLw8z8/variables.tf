variable "server_id" {
  type        = string
  description = "Resource ID of the Postgres Flexible Server."
}

variable "operator_ip" {
  type        = string
  description = "Single IP to allow (e.g. operator's egress for psql admin tasks). Empty disables."
  default     = ""
}

variable "allow_azure_services" {
  type        = bool
  description = "Add the special 0.0.0.0/0 'allow all Azure services' rule. Off by default."
  default     = false
}
