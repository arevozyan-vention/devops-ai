terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/postgres-fw"
}

dependency "postgres" {
  config_path = "../postgres"
  mock_outputs = {
    server_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.DBforPostgreSQL/flexibleServers/mock-pg"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}
