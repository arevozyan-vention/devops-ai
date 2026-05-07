terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/container-apps-env"
}

dependency "rg" {
  config_path = "../resource-group"
  mock_outputs = { name = "mock-rg" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "vnet" {
  config_path = "../vnet"
  mock_outputs = {
    container_apps_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.Network/virtualNetworks/mock-vnet/subnets/mock-aca-subnet"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}
