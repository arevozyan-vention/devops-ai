resource "azurerm_container_registry" "this" {
  name                = replace("${var.name_prefix}${var.suffix}acr", "-", "") # ACR name must be alphanumeric
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku
  admin_enabled       = var.admin_enabled
  tags                = var.tags

  # Note on retention: in azurerm 3.x there was a `retention_policy` block,
  # in 4.x it was removed because retention is governed by ACR Tasks /
  # lifecycle rules in the Premium SKU rather than as a top-level argument
  # on the registry. For our Basic-SKU default, no retention is configured;
  # the operator can switch to Premium and add a separate
  # `azurerm_container_registry_task_schedule_run_now` or use
  # `az acr config retention update` post-apply if they need it.
}
