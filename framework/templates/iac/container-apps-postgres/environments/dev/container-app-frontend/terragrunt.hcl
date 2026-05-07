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
  path = "${get_terragrunt_dir()}/../../_envcommon/container-app-frontend.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name_prefix                  = include.root.locals.name_prefix
  suffix                       = "fe"
  resource_group_name          = dependency.rg.outputs.name
  container_app_environment_id = dependency.env.outputs.id
  identity_id                  = dependency.identity.outputs.id
  acr_login_server             = dependency.acr_frontend.outputs.login_server
  tags                         = include.root.locals.common_tags

  container_name    = try(include.root.locals.project_inputs.frontend_container_name, "frontend")
  target_port       = try(tonumber(include.root.locals.project_inputs.frontend_container_port), 3000)
  health_check_path = try(include.root.locals.project_inputs.frontend_health_check_path, "/")

  cpu          = 0.25
  memory_gib   = 0.5
  min_replicas = 1
  max_replicas = 3

  env_vars = {
    APP_ENV = include.root.locals.env
  }
}
