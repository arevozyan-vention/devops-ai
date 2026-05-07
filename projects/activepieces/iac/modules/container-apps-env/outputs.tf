output "id" {
  value = azurerm_container_app_environment.this.id
}

output "name" {
  value = azurerm_container_app_environment.this.name
}

output "default_domain" {
  description = "*.<this>.azurecontainerapps.io — Container Apps within the env get a subdomain here."
  value       = azurerm_container_app_environment.this.default_domain
}

output "static_ip_address" {
  value = azurerm_container_app_environment.this.static_ip_address
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.this.name
}
