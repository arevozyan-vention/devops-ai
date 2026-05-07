resource "random_password" "admin" {
  length           = 24
  special          = true
  min_special      = 2
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Postgres Flexible Server with VNet integration. Cheaper than Single Server,
# supports Burstable B-series for dev, GP/MO for production.
resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${var.name_prefix}-pg"
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.engine_version
  sku_name            = var.sku

  administrator_login    = var.admin_username
  administrator_password = random_password.admin.result

  storage_mb                   = var.storage_gib * 1024
  storage_tier                 = var.storage_tier
  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup

  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id
  public_network_access_enabled = false

  dynamic "high_availability" {
    for_each = var.high_availability ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  tags = var.tags

  lifecycle {
    # password rotation happens out-of-band (az cli / Key Vault); zone is
    # auto-assigned by Azure on creation and may shift on later applies.
    # NB: don't reference `high_availability[0].standby_availability_zone`
    # here — the dynamic block isn't always present, and an unresolvable
    # path inside `ignore_changes` causes a hard HCL evaluation error.
    # Operators who enable HA can add their own ignore_changes for the
    # standby zone if drift becomes a problem.
    ignore_changes = [administrator_password, zone]
  }
}

# Default app database. Application user does not have CREATEDB on Flexible.
resource "azurerm_postgresql_flexible_server_database" "appdb" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}
