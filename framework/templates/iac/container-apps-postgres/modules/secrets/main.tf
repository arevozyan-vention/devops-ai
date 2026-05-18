data "azurerm_client_config" "current" {}

# Random suffix dodges Azure's 90-day soft-delete name reservation: after a
# destroy, the previous KV name stays globally locked until purge or expiry.
# 10^12 combinations ≈ never collides with our own past deploys; gets a fresh
# value whenever this resource is destroyed and re-applied (state-driven).
resource "random_string" "kv_suffix" {
  length  = 12
  numeric = true
  upper   = false
  lower   = false
  special = false
}

# Project Key Vault. We use RBAC authorization (preferred over access policies)
# so role assignments to the managed identity (in the identity module) take
# effect at the data-plane level too. Soft-delete is enabled by default;
# `purge_protection_enabled` is left configurable for dev convenience.
# Name format: "kv<12-digit-random>" — project identification via tags.
resource "azurerm_key_vault" "this" {
  name                = "kv${random_string.kv_suffix.result}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = var.sku
  tenant_id           = data.azurerm_client_config.current.tenant_id

  # azurerm 4.x renamed `enable_rbac_authorization` → `rbac_authorization_enabled`.
  rbac_authorization_enabled    = true
  purge_protection_enabled      = var.purge_protection
  soft_delete_retention_days    = var.soft_delete_days
  public_network_access_enabled = true # tighten in prod via private endpoint
  tags                          = var.tags
}

# Per-secret 64-char hex value, generated at apply time. Equivalent to
# `openssl rand -hex 32`, the convention most apps document for JWT /
# encryption / session secrets. Pre-filling here saves deploy-app's
# self-heal loop from discovering empty secrets, generating values, and
# retrying a revision — that pattern costs 1-3 minutes and 100k+ AI
# tokens per deploy.
#
# App-internal secrets only. External credentials (Stripe, SMTP, OAuth
# client_secret) the operator overwrites manually after apply; the
# `ignore_changes = [value]` lifecycle on the KV secret means terraform
# won't snap those overrides back to the random value on next apply.
resource "random_id" "secret_value" {
  for_each    = toset(var.secret_names)
  byte_length = lookup(var.secret_byte_lengths, each.key, 32)
}

# Application secrets in Key Vault, pre-populated with random hex values.
# The Container App references these via secretRef so values can be rotated
# (deploy-app's pre-fix overwrites db-password with the real Postgres admin
# password from outputs; operator overwrites external API keys manually).
resource "azurerm_key_vault_secret" "placeholder" {
  for_each     = toset(var.secret_names)
  name         = each.value
  value        = random_id.secret_value[each.value].hex
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"

  # NB: no `ignore_changes = [value]`. Terraform is the source of truth for
  # system-managed secrets — Postgres reads our password via Terragrunt
  # dependency, so any drift between terraform state and the actual stored
  # value would re-introduce the auth mismatch we fixed with Variant A.
  # External operator-managed secrets (Stripe, SMTP, OAuth client_secret)
  # MUST live outside this module — create them as separate
  # azurerm_key_vault_secret resources or use az CLI to set values on
  # secrets that are NOT in the `secret_names` list.

  # The current-config principal needs role permission to write the initial
  # value — added below.
  depends_on = [azurerm_role_assignment.bootstrap_writer]
}

# Grant the principal running terraform "Key Vault Secrets Officer" so it
# can write the placeholder secret values during apply.
resource "azurerm_role_assignment" "bootstrap_writer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
