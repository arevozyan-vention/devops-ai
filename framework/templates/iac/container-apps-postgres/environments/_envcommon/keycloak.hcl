terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/keycloak"
}

dependency "rg" {
  config_path = "../resource-group"
  mock_outputs = { name = "mock-rg" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "env" {
  config_path = "../container-apps-env"
  mock_outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.App/managedEnvironments/mock-env" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "identity" {
  config_path = "../identity"
  mock_outputs = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mock-id" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}

dependency "postgres" {
  config_path = "../postgres"
  mock_outputs = {
    server_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.DBforPostgreSQL/flexibleServers/mock-pg"
    fqdn           = "mock-pg.private.postgres.database.azure.com"
    admin_username = "pgadmin"
    admin_password = "MOCK_PASSWORD"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}
