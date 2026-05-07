resource "azurerm_storage_account" "this" {
  name                          = substr(replace("${var.name_prefix}q", "-", ""), 0, 24)
  resource_group_name           = var.resource_group_name
  location                      = var.location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  shared_access_key_enabled     = true # Storage Queue currently still uses keys; leave on
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_storage_queue" "main" {
  name               = "${var.name_prefix}-q"
  storage_account_id = azurerm_storage_account.this.id
}

resource "azurerm_storage_queue" "dlq" {
  name               = "${var.name_prefix}-q-dlq"
  storage_account_id = azurerm_storage_account.this.id
}
