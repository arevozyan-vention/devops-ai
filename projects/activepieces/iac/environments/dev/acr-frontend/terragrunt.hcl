locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

# Opt-in: deploys only when include_frontend = "true" in inputs.yaml.
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
  path = "${get_terragrunt_dir()}/../../_envcommon/acr-frontend.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name_prefix         = include.root.locals.name_prefix
  suffix              = "fe"
  resource_group_name = dependency.rg.outputs.name
  location            = include.root.locals.region
  tags                = include.root.locals.common_tags
  sku                 = "Basic"
  admin_enabled       = false
}
