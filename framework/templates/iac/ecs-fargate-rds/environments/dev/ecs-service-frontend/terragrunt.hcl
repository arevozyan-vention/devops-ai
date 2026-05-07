locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
  env_inputs  = read_terragrunt_config(find_in_parent_folders("env.hcl")).inputs
}

# Opt-in: deploys only when include_frontend = "true" in inputs.yaml.
# Otherwise terragrunt excludes this unit from `run --all` and from any
# direct invocation.
exclude {
  if                   = !try(local.inputs_yaml.include_frontend == "true", false)
  actions              = ["all"]
  exclude_dependencies = false
}

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/ecs-service-frontend.hcl"
  merge_strategy = "deep"
}

inputs = {
  name = "${include.root.locals.name_prefix}-frontend-svc"

  cpu           = local.env_inputs.ecs_cpu
  memory        = local.env_inputs.ecs_memory
  desired_count = local.env_inputs.ecs_desired_count

  tags = include.root.locals.common_tags
}
