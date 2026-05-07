output "fqdn" {
  value = azurerm_container_app.keycloak.latest_revision_fqdn
}
output "admin_password" {
  value     = random_password.kc_admin.result
  sensitive = true
}
