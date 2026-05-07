locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

# Opt-in: this unit deploys only if include_alb_https is set to "true" in
# inputs.yaml. Use it when you don't have a real domain + ACM cert but a
# component (typically Keycloak) requires HTTPS. Browsers warn once about
# the self-signed cert; production stacks should use a real cert instead.
# Uses the `exclude {}` block introduced in Terragrunt 1.x; the older
# `skip = ...` attribute was removed.
exclude {
  if                   = !try(local.inputs_yaml.include_alb_https == "true", false)
  actions              = ["all"]
  exclude_dependencies = false
}

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/alb-https.hcl"
  merge_strategy = "deep"
}

inputs = {
  tags = include.root.locals.common_tags
}
