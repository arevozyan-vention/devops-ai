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
  # Resolves both paths: the in-module random_password fallback (legacy) AND
  # the value passed in via var.admin_password (Variant A wiring from secrets
  # module). Plain `random_password.admin.result` no longer works because the
  # resource is now conditional with `count`.
  value     = local.pg_admin_password
  sensitive = true
}

output "db_name" {
  value = azurerm_postgresql_flexible_server_database.appdb.name
}

# DSN string for the Container App.
output "connection_string" {
  value     = "postgresql://${azurerm_postgresql_flexible_server.this.administrator_login}:${local.pg_admin_password}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.appdb.name}?sslmode=require"
  sensitive = true
}
