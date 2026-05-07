terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/container-app"
}

dependency "rg" {
  config_path                             = "../resource-group"
  mock_outputs                            = { name = "mock-rg" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "env" {
  config_path = "../container-apps-env"
  mock_outputs = {
    id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.App/managedEnvironments/mock-env"
    default_domain = "mock.eastus.azurecontainerapps.io"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "identity" {
  config_path = "../identity"
  mock_outputs = {
    id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mock-id"
    client_id = "00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "acr_frontend" {
  config_path = "../acr-frontend"
  mock_outputs = {
    login_server = "mockacrfe.azurecr.io"
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.ContainerRegistry/registries/mockacrfe"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}
