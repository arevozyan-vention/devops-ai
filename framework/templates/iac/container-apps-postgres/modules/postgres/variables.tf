variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "engine_version" {
  type        = string
  description = "Postgres major version (e.g. \"16\")."
}

variable "sku" {
  type        = string
  description = "Tier_Family_Size, e.g. B_Standard_B1ms (Burstable), GP_Standard_D2s_v3 (General Purpose)."
}

variable "storage_gib" {
  type    = number
  default = 32
}

variable "storage_tier" {
  type        = string
  description = "P4..P80 — IOPS performance tier. P4 = 120 IOPS baseline."
  default     = "P4"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "geo_redundant_backup" {
  type    = bool
  default = false
}

variable "high_availability" {
  type    = bool
  default = false
}

variable "admin_username" {
  type    = string
  default = "pgadmin"
}

# Postgres administrator password. When empty, the module generates a random
# 24-char password locally (legacy fallback) — this is the historical
# behaviour but creates drift: the app's KV secret holds an unrelated random
# value, and the actual DB rejects the app's auth. Pass the same value here
# that the secrets module wrote to KV (via Terragrunt dependency wiring) so
# both ends agree by construction.
variable "admin_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Master DB password. Empty = generate locally (legacy). Pass from secrets module to keep KV and DB in sync."
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "delegated_subnet_id" {
  type        = string
  description = "Subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers."
}

variable "private_dns_zone_id" {
  type        = string
  description = "Private DNS zone used for the server's *.private.postgres.database.azure.com hostname."
}

variable "tags" {
  type    = map(string)
  default = {}
}
