# Postgres Flexible Server firewall rule. AWS analog: rds-sg ingress rule.
#
# With VNet integration the server is already private; this rule scopes
# *outside* access — for Azure-provided services (Allow-AzureServices) when
# needed, or for the operator's own admin IP when debugging.
#
# When the Container App lives in the delegated ACA subnet of the same VNet
# as the postgres server, no firewall rule is needed at all — traffic is
# private. We still keep this module for the explicit op-IP case and as a
# place to add a `0.0.0.0` allow-Azure-services rule if a future opt-in
# component demands it.

resource "azurerm_postgresql_flexible_server_firewall_rule" "operator_ip" {
  count            = var.operator_ip == "" ? 0 : 1
  name             = "operator-ip"
  server_id        = var.server_id
  start_ip_address = var.operator_ip
  end_ip_address   = var.operator_ip
}

# 0.0.0.0/0 is a special "allow Azure services" sentinel value when
# start=end=0.0.0.0. Off by default — only flip on if a specific Azure
# integration requires it.
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  count            = var.allow_azure_services ? 1 : 0
  name             = "AllowAllAzureServicesAndResourcesWithinAzureIps"
  server_id        = var.server_id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
