variable "name_prefix" { type = string }
variable "resource_group_name" { type = string }
variable "container_app_environment_id" { type = string }
variable "identity_id" { type = string }
variable "postgres_server_id" { type = string }
variable "postgres_fqdn" { type = string }
variable "postgres_admin_username" { type = string }

variable "postgres_admin_password" {
  type      = string
  sensitive = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
