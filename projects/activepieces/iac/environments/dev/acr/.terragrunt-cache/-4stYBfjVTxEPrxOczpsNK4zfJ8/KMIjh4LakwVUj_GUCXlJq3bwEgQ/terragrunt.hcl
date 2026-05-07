include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path = "${get_terragrunt_dir()}/../../_envcommon/acr.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name_prefix         = include.root.locals.name_prefix
  resource_group_name = dependency.rg.outputs.name
  location            = include.root.locals.region
  tags                = include.root.locals.common_tags
  # sku, admin_enabled come from env.hcl (acr_sku, acr_admin_enabled)
  sku           = "Basic"
  admin_enabled = false
}
