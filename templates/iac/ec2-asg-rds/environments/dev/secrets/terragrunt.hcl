include "root" {
  path = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/secrets.hcl"
  merge_strategy = "deep"
}

locals {
  env_inputs = read_terragrunt_config(find_in_parent_folders("env.hcl")).inputs
}

inputs = {
  project_name = include.root.locals.project_name
  env          = include.root.locals.env
  name_prefix  = include.root.locals.name_prefix
  common_tags  = include.root.locals.common_tags

  recovery_window_in_days = local.env_inputs.secrets_recovery_days
}
