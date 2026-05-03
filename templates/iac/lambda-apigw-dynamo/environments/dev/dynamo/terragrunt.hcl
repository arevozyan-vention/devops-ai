include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/dynamo.hcl"
  merge_strategy = "deep"
}

locals {
  env_inputs = read_terragrunt_config(find_in_parent_folders("env.hcl")).inputs
}

inputs = {
  name = "${include.root.locals.name_prefix}-table"

  point_in_time_recovery_enabled = local.env_inputs.dynamo_pitr

  tags = include.root.locals.common_tags
}
