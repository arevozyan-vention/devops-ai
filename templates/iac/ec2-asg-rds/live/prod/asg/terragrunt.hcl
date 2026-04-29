include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/asg.hcl"
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

  instance_type = local.env_inputs.asg_instance_type
  min_size      = local.env_inputs.asg_min_size
  desired_size  = local.env_inputs.asg_desired_size
  max_size      = local.env_inputs.asg_max_size
}
