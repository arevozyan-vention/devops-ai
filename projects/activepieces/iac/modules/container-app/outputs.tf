output "id" {
  value = azurerm_container_app.this.id
}

output "name" {
  value = azurerm_container_app.this.name
}

output "fqdn" {
  description = "Public ingress FQDN, e.g. <app>.<env-domain>.<region>.azurecontainerapps.io"
  value       = azurerm_container_app.this.latest_revision_fqdn
}

output "url" {
  value = "https://${azurerm_container_app.this.latest_revision_fqdn}"
}

output "latest_revision_name" {
  value = azurerm_container_app.this.latest_revision_name
}
