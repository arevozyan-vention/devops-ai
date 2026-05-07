output "storage_account_name" { value = azurerm_storage_account.this.name }
output "queue_name" { value = azurerm_storage_queue.main.name }
output "dlq_name" { value = azurerm_storage_queue.dlq.name }
output "queue_url" {
  value = "${azurerm_storage_account.this.primary_queue_endpoint}${azurerm_storage_queue.main.name}"
}
output "dlq_url" {
  value = "${azurerm_storage_account.this.primary_queue_endpoint}${azurerm_storage_queue.dlq.name}"
}
output "primary_connection_string" {
  value     = azurerm_storage_account.this.primary_connection_string
  sensitive = true
}
