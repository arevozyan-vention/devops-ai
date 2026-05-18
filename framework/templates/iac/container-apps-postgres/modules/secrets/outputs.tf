output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "secret_ids" {
  description = "Map of secret_name → secret resource ID."
  value       = { for k, s in azurerm_key_vault_secret.placeholder : k => s.id }
}

output "secret_uris" {
  description = "Map of secret_name → versionless URI for Container App secretRef."
  value = {
    for k, s in azurerm_key_vault_secret.placeholder :
    k => "${azurerm_key_vault.this.vault_uri}secrets/${s.name}"
  }
}

# Plaintext values, exposed so the postgres module can wire the same value
# as `administrator_password` and avoid drift where Postgres has one random
# password while the app's KV secret holds a different one. Sensitive —
# Terragrunt won't print it in plan output.
output "secret_values_by_key" {
  description = "Map from secret name to its current generated value."
  value       = { for k in toset(var.secret_names) : k => random_id.secret_value[k].hex }
  sensitive   = true
}
