terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/custom-domain-https"
}

dependency "container_app" {
  config_path = "../container-app"
  mock_outputs = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mock/providers/Microsoft.App/containerApps/mock-app"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "init", "plan"]
}
