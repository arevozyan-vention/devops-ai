terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/identity"
}

dependency "rg" {
  config_path                             = "../resource-group"
  mock_outputs                            = { name = "mock-rg" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "acr" {
  config_path                             = "../acr"
  mock_outputs                            = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.ContainerRegistry/registries/mock" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "secrets" {
  config_path                             = "../secrets"
  mock_outputs                            = { key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.KeyVault/vaults/mock" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}
