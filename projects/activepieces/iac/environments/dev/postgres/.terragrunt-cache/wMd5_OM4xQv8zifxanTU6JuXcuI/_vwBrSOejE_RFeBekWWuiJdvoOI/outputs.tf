output "server_id" {
  value = azurerm_postgresql_flexible_server.this.id
}

output "server_name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "admin_username" {
  value = azurerm_postgresql_flexible_server.this.administrator_login
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

output "db_name" {
  value = azurerm_postgresql_flexible_server_database.appdb.name
}

# DSN string for the Container App.
output "connection_string" {
  value     = "postgresql://${azurerm_postgresql_flexible_server.this.administrator_login}:${random_password.admin.result}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.appdb.name}?sslmode=require"
  sensitive = true
}
