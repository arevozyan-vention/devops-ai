locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

# Opt-in: deploys only when include_keycloak = "true" in inputs.yaml.
# (`exclude {}` is Terragrunt 1.x; older `skip = ...` was removed.)
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
  path = "${get_terragrunt_dir()}/../../_envcommon/keycloak.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name_prefix                  = include.root.locals.name_prefix
  resource_group_name          = dependency.rg.outputs.name
  container_app_environment_id = dependency.env.outputs.id
  identity_id                  = dependency.identity.outputs.id
  postgres_server_id           = dependency.postgres.outputs.server_id
  postgres_fqdn                = dependency.postgres.outputs.fqdn
  postgres_admin_username      = dependency.postgres.outputs.admin_username
  postgres_admin_password      = dependency.postgres.outputs.admin_password
  tags                         = include.root.locals.common_tags
}
