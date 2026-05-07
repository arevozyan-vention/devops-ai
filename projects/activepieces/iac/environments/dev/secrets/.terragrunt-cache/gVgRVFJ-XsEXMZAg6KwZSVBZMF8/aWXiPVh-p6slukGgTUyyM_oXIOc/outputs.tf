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
