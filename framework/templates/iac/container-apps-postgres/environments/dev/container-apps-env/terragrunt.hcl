include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path = "${get_terragrunt_dir()}/../../_envcommon/container-apps-env.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name_prefix              = include.root.locals.name_prefix
  resource_group_name      = dependency.rg.outputs.name
  location                 = include.root.locals.region
  tags                     = include.root.locals.common_tags
  infrastructure_subnet_id = dependency.vnet.outputs.container_apps_subnet_id
  log_retention_days       = try(tonumber(include.root.locals.project_inputs.log_retention_days), 30)
}
