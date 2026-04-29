include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/alb.hcl"
  merge_strategy = "deep"
}

locals {
  env_inputs = read_terragrunt_config(find_in_parent_folders("env.hcl")).inputs
}

inputs = {
  name = "${include.root.locals.name_prefix}-alb"

  enable_deletion_protection = local.env_inputs.alb_deletion_protection

  tags = include.root.locals.common_tags
}
