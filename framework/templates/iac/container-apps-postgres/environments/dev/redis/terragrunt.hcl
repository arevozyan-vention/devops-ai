locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

# Opt-in: deploys only when include_redis = "true" in inputs.yaml.
# (`exclude {}` is Terragrunt 1.x; older `skip = ...` was removed.)
exclude {
  if                   = !try(local.inputs_yaml.include_redis == "true", false)
  actions              = ["all"]
  exclude_dependencies = false
}

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path = "${get_terragrunt_dir()}/../../_envcommon/redis.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name_prefix         = include.root.locals.name_prefix
  resource_group_name = dependency.rg.outputs.name
  location            = include.root.locals.region
  tags                = include.root.locals.common_tags

  capacity = 0          # C0 = 250 MB, ~$17/mo
  family   = "C"
  sku      = "Basic"
}
