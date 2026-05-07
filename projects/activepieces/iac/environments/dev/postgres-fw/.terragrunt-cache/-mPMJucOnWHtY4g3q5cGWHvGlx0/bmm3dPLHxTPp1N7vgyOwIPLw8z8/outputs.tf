output "operator_rule_id" {
  value = try(azurerm_postgresql_flexible_server_firewall_rule.operator_ip[0].id, null)
}

output "azure_services_rule_id" {
  value = try(azurerm_postgresql_flexible_server_firewall_rule.allow_azure_services[0].id, null)
}
