output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "container_apps_subnet_id" {
  value = azurerm_subnet.container_apps.id
}

output "container_apps_subnet_cidr" {
  value = var.subnet_container_apps_cidr
}

output "postgres_subnet_id" {
  value = azurerm_subnet.postgres.id
}

output "postgres_private_dns_zone_id" {
  value = azurerm_private_dns_zone.postgres.id
}

output "postgres_private_dns_zone_name" {
  value = azurerm_private_dns_zone.postgres.name
}
