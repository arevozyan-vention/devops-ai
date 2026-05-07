locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

# Opt-in: deploys only when include_custom_domain_https = "true" in inputs.yaml.
exclude {
  if                   = !try(local.inputs_yaml.include_custom_domain_https == "true", false)
  actions              = ["all"]
  exclude_dependencies = false
}

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path = "${get_terragrunt_dir()}/../../_envcommon/custom-domain-https.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  custom_domain    = include.root.locals.project_inputs.domain_name
  container_app_id = dependency.container_app.outputs.id
}
