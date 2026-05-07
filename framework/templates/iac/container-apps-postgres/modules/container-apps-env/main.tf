# Container Apps Environment — the runtime context for all Container Apps
# in the project. Analog of an ECS cluster, but also bundles the L7 ingress,
# log workspace and observability backplane.

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-logs"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_container_app_environment" "this" {
  name                       = "${var.name_prefix}-aca-env"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = var.infrastructure_subnet_id

  # Internal load balancer = false → environment is reachable from internet.
  # Set true to confine to VNet (then a separate App Gateway / Front Door
  # publishes it).
  internal_load_balancer_enabled = false

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = var.tags
}
