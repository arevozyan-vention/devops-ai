terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/queue"
}

dependency "rg" {
  config_path = "../resource-group"
  mock_outputs = { name = "mock-rg" }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}
