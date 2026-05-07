include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path = "${get_terragrunt_dir()}/../../_envcommon/secrets.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name_prefix         = include.root.locals.name_prefix
  resource_group_name = dependency.rg.outputs.name
  location            = include.root.locals.region
  tags                = include.root.locals.common_tags

  sku              = "standard"
  purge_protection = false
  soft_delete_days = 7

  # Activepieces sensitive config (overview "Required env vars" → secret=yes).
  # Key Vault names must be [0-9A-Za-z-] only, so the container-app unit
  # re-maps these dashed names back to AP_* env var names.
  # Operator (or deploy-app pre-fix) writes real values via
  # `az keyvault secret set` after apply.
  secret_names = [
    "ap-jwt-secret",
    "ap-encryption-key",
    "ap-postgres-password",
  ]
}
