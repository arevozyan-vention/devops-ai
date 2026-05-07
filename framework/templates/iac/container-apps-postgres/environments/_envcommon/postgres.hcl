terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/postgres"
}

dependency "rg" {
  config_path = "../resource-group"
  mock_outputs = { name = "mock-rg" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "vnet" {
  config_path = "../vnet"
  mock_outputs = {
    postgres_subnet_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.Network/virtualNetworks/mock-vnet/subnets/mock-postgres-subnet"
    postgres_private_dns_zone_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.Network/privateDnsZones/mock.private.postgres.database.azure.com"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}
