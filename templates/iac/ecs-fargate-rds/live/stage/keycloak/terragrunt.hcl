locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

# Opt-in: this unit deploys only if include_keycloak is set to "true" in
# inputs.yaml. Otherwise terragrunt excludes it from `run --all` and from
# any direct invocation. Use `exclude { ... }` (Terragrunt 1.x stargazer);
# the older `skip = ...` attribute was removed.
exclude {
  if                   = !try(local.inputs_yaml.include_keycloak == "true", false)
  actions              = ["all"]
  exclude_dependencies = false
}

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/keycloak.hcl"
  merge_strategy = "deep"
}

inputs = {
  name = "${include.root.locals.name_prefix}-kc"

  cpu           = 512
  memory        = 1024
  desired_count = 1

  tags = include.root.locals.common_tags
}
