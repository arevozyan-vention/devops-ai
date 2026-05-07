output "id" { value = azurerm_redis_cache.this.id }
output "hostname" { value = azurerm_redis_cache.this.hostname }
output "ssl_port" { value = azurerm_redis_cache.this.ssl_port }
output "primary_access_key" {
  value     = azurerm_redis_cache.this.primary_access_key
  sensitive = true
}
output "redis_url" {
  description = "rediss://:<key>@<host>:<port>"
  value       = "rediss://:${azurerm_redis_cache.this.primary_access_key}@${azurerm_redis_cache.this.hostname}:${azurerm_redis_cache.this.ssl_port}"
  sensitive   = true
}
