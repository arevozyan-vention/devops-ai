# _envcommon/iam.hcl — task execution role + task role for the ECS service.
# Uses a small local module so we can express permissions tightly without
# pulling in a heavyweight IAM module.

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/iam"
}

dependency "secrets" {
  config_path = "../secrets"
  mock_outputs = {
    secret_arns_by_key = {}
    all_secret_arns    = []
  }
}

inputs = {
  # Permissions to read the application's Secrets Manager entries are derived
  # from the secrets component's outputs, so adding a new secret automatically
  # extends the policy.
  secret_arns = dependency.secrets.outputs.all_secret_arns
}
