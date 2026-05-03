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
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/ecr.hcl"
  merge_strategy = "deep"
}

inputs = {
  # Suffixed name keeps the backend repo (`<project>`) untouched.
  repository_name = "${include.root.locals.name_prefix}-frontend"

  tags = include.root.locals.common_tags
}
