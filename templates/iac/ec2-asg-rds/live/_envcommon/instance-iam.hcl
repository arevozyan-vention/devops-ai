# _envcommon/instance-iam.hcl — IAM instance profile for the ASG instances.

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/instance-iam"
}

dependency "secrets" {
  config_path = "../secrets"
  mock_outputs = {
    all_secret_arns = []
  }
}

locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

inputs = {
  artifact_bucket = local.inputs_yaml.artifact_bucket
  secret_arns     = dependency.secrets.outputs.all_secret_arns
}
