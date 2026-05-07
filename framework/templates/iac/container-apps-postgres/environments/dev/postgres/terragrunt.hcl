include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path = "${get_terragrunt_dir()}/../../_envcommon/postgres.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name_prefix         = include.root.locals.name_prefix
  resource_group_name = dependency.rg.outputs.name
  location            = include.root.locals.region
  tags                = include.root.locals.common_tags

  engine_version  = try(include.root.locals.project_inputs.db_engine_version, "16")
  admin_username  = try(include.root.locals.project_inputs.db_admin_username, "pgadmin")
  db_name         = try(include.root.locals.project_inputs.db_name, "appdb")

  delegated_subnet_id = dependency.vnet.outputs.postgres_subnet_id
  private_dns_zone_id = dependency.vnet.outputs.postgres_private_dns_zone_id

  # sku / storage / HA come from env.hcl (postgres_sku, postgres_storage_gib, postgres_high_availability)
  sku                   = "B_Standard_B1ms"
  storage_gib           = 32
  storage_tier          = "P4"
  backup_retention_days = 7
  geo_redundant_backup  = false
  high_availability     = false
}
