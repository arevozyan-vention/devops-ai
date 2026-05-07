data "azurerm_client_config" "current" {}

# Project Key Vault. We use RBAC authorization (preferred over access policies)
# so role assignments to the managed identity (in the identity module) take
# effect at the data-plane level too. Soft-delete is enabled by default;
# `purge_protection_enabled` is left configurable for dev convenience.
resource "azurerm_key_vault" "this" {
  name                = substr(replace("${var.name_prefix}-kv", "_", "-"), 0, 24)
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

# Empty placeholder secrets — the operator (or deploy-app's pre-fix phase)
# populates real values via `az keyvault secret set` after this is applied.
# The Container App references these via secretRef so values can be rotated
# without redeploying the app.
resource "azurerm_key_vault_secret" "placeholder" {
  for_each     = toset(var.secret_names)
  name         = each.value
  value        = "PLACEHOLDER-CHANGE-ME"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"

  # Don't drift on value updates from out-of-band rotation.
  lifecycle {
    ignore_changes = [value, content_type]
  }

  # The current-config principal needs role permission to write the initial
  # placeholder — added below.
  depends_on = [azurerm_role_assignment.bootstrap_writer]
}

# Grant the principal running terraform "Key Vault Secrets Officer" so it
# can write the placeholder secret values during apply.
resource "azurerm_role_assignment" "bootstrap_writer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
