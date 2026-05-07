# User-assigned managed identity attached to the Container App. Replaces
# the AWS-side IAM task-role + execution-role pair. The Container App will
# pull from ACR and read from Key Vault as this identity.

resource "azurerm_user_assigned_identity" "this" {
  name                = "${var.name_prefix}-id"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# AcrPull on the registry. Lets the Container App pull images without an
# admin password.
resource "azurerm_role_assignment" "acr_pull" {
  count                = var.acr_id == "" ? 0 : 1
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# Key Vault Secrets User on the vault. Lets the Container App resolve
# secret references at runtime via the secretRef mechanism.
resource "azurerm_role_assignment" "kv_secrets_user" {
  count                = var.key_vault_id == "" ? 0 : 1
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}
