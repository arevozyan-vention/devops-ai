resource "azurerm_redis_cache" "this" {
  name                 = "${var.name_prefix}-redis"
  resource_group_name  = var.resource_group_name
  location             = var.location
  capacity             = var.capacity # 0..6 for Basic/Standard
  family               = var.family   # C (Basic/Standard) or P (Premium)
  sku_name             = var.sku      # Basic | Standard | Premium
  non_ssl_port_enabled = false
  minimum_tls_version  = "1.2"
  tags                 = var.tags

  # `redis_configuration` is REQUIRED in azurerm 4.x even when empty.
  # Notes on tunables:
  #  - `maxmemory_policy` is NOT supported on the Basic SKU (Azure rejects
  #    it at apply time with "maxmemory_policy is not supported for Basic
  #    sku"). Add it conditionally only when sku != Basic.
  #  - Other settings (rdb backup, aof) require Premium.
  redis_configuration {
    maxmemory_policy = var.sku == "Basic" ? null : "allkeys-lru"
  }
}
