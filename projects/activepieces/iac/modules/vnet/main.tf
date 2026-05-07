resource "azurerm_virtual_network" "this" {
  name                = "${var.name_prefix}-vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

# Subnet for Container Apps Environment.
# ACA requires:
#   - At least /23 (512 addresses) for Consumption profile
#   - Service delegation to Microsoft.App/environments
#   - No NSG rules blocking outbound (it manages its own)
resource "azurerm_subnet" "container_apps" {
  name                 = "${var.name_prefix}-aca-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_container_apps_cidr]

  delegation {
    name = "aca-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Subnet for Postgres Flexible Server with VNet integration.
# Requires service delegation to Microsoft.DBforPostgreSQL/flexibleServers.
resource "azurerm_subnet" "postgres" {
  name                 = "${var.name_prefix}-postgres-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_postgres_cidr]

  delegation {
    name = "postgres-delegation"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }

  # Postgres Flexible needs the VNet endpoint for storage to work correctly.
  service_endpoints = ["Microsoft.Storage"]
}

# Private DNS zone for the postgres server's VNet endpoint. Without this,
# the app inside the ACA subnet can't resolve <server>.postgres.database.azure.com.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name_prefix}.private.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${var.name_prefix}-postgres-dns-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}
