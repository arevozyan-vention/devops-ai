include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path = "${get_terragrunt_dir()}/../../_envcommon/container-app.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name_prefix                  = include.root.locals.name_prefix
  resource_group_name          = dependency.rg.outputs.name
  container_app_environment_id = dependency.env.outputs.id
  identity_id                  = dependency.identity.outputs.id
  acr_login_server             = dependency.acr.outputs.login_server
  tags                         = include.root.locals.common_tags

  container_name    = try(include.root.locals.project_inputs.container_name, "app")
  target_port       = try(tonumber(include.root.locals.project_inputs.container_port), 8080)
  health_check_path = try(include.root.locals.project_inputs.health_check_path, "/")

  # sizing — overridden by env.hcl
  cpu          = 0.5
  memory_gib   = 1.0
  min_replicas = 1
  max_replicas = 3

  env_vars = {
    APP_ENV     = include.root.locals.env
    DB_HOST     = dependency.postgres.outputs.fqdn
    DB_NAME     = dependency.postgres.outputs.db_name
    DB_USER     = dependency.postgres.outputs.admin_username
    PGSSLMODE   = "require"
  }

  # Each entry becomes both an ACA secret (sourced from Key Vault) and an
  # env var of the same name in the container.
  kv_secret_uris = dependency.secrets.outputs.secret_uris
}
