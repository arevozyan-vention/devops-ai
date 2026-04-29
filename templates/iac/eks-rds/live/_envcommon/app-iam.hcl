# _envcommon/app-iam.hcl — IRSA role for the application's K8s service account.

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/app-iam"
}

dependency "eks" {
  config_path = "../eks"
  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/MOCK"
    oidc_provider     = "oidc.eks.us-east-1.amazonaws.com/id/MOCK"
  }
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
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn
  oidc_provider_url = dependency.eks.outputs.oidc_provider

  namespace       = local.inputs_yaml.app_namespace
  service_account = local.inputs_yaml.app_service_account

  secret_arns = dependency.secrets.outputs.all_secret_arns
}
