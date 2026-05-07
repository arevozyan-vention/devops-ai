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

  # Non-sensitive activepieces env vars (overview "Required env vars").
  # AP_FRONTEND_URL is derived from the deterministic ACA FQDN
  # `<app-name>.<env-default-domain>`; activepieces breaks webhook delivery
  # without it. AP_CONTAINER_TYPE=WORKER_AND_APP runs API+worker in one
  # container (the project default suitable for dev). AP_POSTGRES_USE_SSL is
  # required against Azure Postgres Flexible Server.
  env_vars = {
    AP_ENVIRONMENT       = include.root.locals.env
    AP_CONTAINER_TYPE    = "WORKER_AND_APP"
    AP_FRONTEND_URL      = "https://${include.root.locals.name_prefix}.${dependency.env.outputs.default_domain}"
    AP_POSTGRES_HOST     = dependency.postgres.outputs.fqdn
    AP_POSTGRES_PORT     = "5432"
    AP_POSTGRES_DATABASE = dependency.postgres.outputs.db_name
    AP_POSTGRES_USERNAME = dependency.postgres.outputs.admin_username
    AP_POSTGRES_USE_SSL  = "true"
  }

  # Map AP_* env var names → Key Vault URIs. The container-app module turns
  # each map key into both an ACA secret (lowercased+dashed) and an env var
  # bearing the original key name. The Key Vault secret names live in
  # ../secrets/terragrunt.hcl and use a dashed form because Key Vault
  # forbids underscores in names.
  kv_secret_uris = {
    AP_JWT_SECRET        = lookup(dependency.secrets.outputs.secret_uris, "ap-jwt-secret", "")
    AP_ENCRYPTION_KEY    = lookup(dependency.secrets.outputs.secret_uris, "ap-encryption-key", "")
    AP_POSTGRES_PASSWORD = lookup(dependency.secrets.outputs.secret_uris, "ap-postgres-password", "")
  }
}
