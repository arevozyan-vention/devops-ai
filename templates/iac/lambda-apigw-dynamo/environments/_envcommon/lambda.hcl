# _envcommon/lambda.hcl — container-image Lambda function.

terraform {
  source = "tfr:///terraform-aws-modules/lambda/aws?version=7.20.1"
}

dependency "ecr"     { config_path = "../ecr" }
dependency "secrets" { config_path = "../secrets" }
dependency "dynamo"  { config_path = "../dynamo" }

locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

inputs = {
  function_name = ""  # filled per-env

  package_type = "Image"
  image_uri    = "${dependency.ecr.outputs.repository_url}:latest"

  create_package = false

  # Memory and timeout overridden per-env via env.hcl.
  memory_size = 512
  timeout     = 30

  # TODO(devops-ai): merge env vars from the overview here. Sensitive values
  # must instead reference Secrets Manager via the function's runtime fetch
  # path (or via Lambda extension), not be inlined here.
  environment_variables = {
    DYNAMO_TABLE = dependency.dynamo.outputs.dynamodb_table_id
  }

  attach_policy_statements = true
  policy_statements = {
    secrets = {
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = length(dependency.secrets.outputs.all_secret_arns) > 0 ? dependency.secrets.outputs.all_secret_arns : ["*"]
    }
    dynamo = {
      effect    = "Allow"
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"]
      resources = [dependency.dynamo.outputs.dynamodb_table_arn]
    }
  }

  cloudwatch_logs_retention_in_days = tonumber(local.inputs_yaml.log_retention_days)
}
