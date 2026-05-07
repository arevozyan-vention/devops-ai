# environments/dev/env.hcl — environment-specific values for dev.
# Read by both the root terragrunt.hcl (for env name + tags) and by every
# leaf terragrunt.hcl (for sizing / scaling overrides).

inputs = {
  env = "dev"

  # Networking
  vnet_cidr                  = "10.30.0.0/16"
  subnet_container_apps_cidr = "10.30.0.0/23"   # /23 required by ACA infrastructure
  subnet_postgres_cidr       = "10.30.4.0/24"

  # Container Apps — workload sizing. ACA Consumption profile bills per
  # vCPU-second + memory-second + request, with scale-to-zero between
  # requests. 0.5/1.0 is the smallest combo that doesn't get OOM-killed by
  # typical Node/Bun/Python boots.
  aca_cpu             = 0.5
  aca_memory_gib      = 1.0
  aca_min_replicas    = 1
  aca_max_replicas    = 3
  aca_workload_profile = "Consumption"   # alt: "D4" / "D8" for dedicated

  # Postgres Flexible Server. Burstable B1ms is roughly equivalent to
  # AWS db.t4g.micro — cheap, ~$13/mo, fine for dev. Storage min is 32 GiB.
  postgres_sku                  = "B_Standard_B1ms"
  postgres_storage_gib          = 32
  postgres_storage_tier         = "P4"      # IOPS tier; P4 = 120 IOPS baseline
  postgres_high_availability    = false
  postgres_backup_retention     = 7         # days
  postgres_geo_redundant_backup = false

  # ACR
  acr_sku           = "Basic"   # alt: Standard, Premium (for geo-replication)
  acr_admin_enabled = false     # stay disabled — pull via managed identity

  # Key Vault
  kv_sku                   = "standard"
  kv_purge_protection      = false   # dev convenience — soft-delete still applies
  kv_soft_delete_days      = 7

  # App-level env var passed to the container (purely informational).
  app_env = "dev"
}
