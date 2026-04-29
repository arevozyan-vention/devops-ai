include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/ecs-service.hcl"
  merge_strategy = "deep"
}

locals {
  env_inputs = read_terragrunt_config(find_in_parent_folders("env.hcl")).inputs
}

inputs = {
  name = "${include.root.locals.name_prefix}-svc"

  cpu           = local.env_inputs.ecs_cpu
  memory        = local.env_inputs.ecs_memory
  desired_count = local.env_inputs.ecs_desired_count

  tags = include.root.locals.common_tags
}
