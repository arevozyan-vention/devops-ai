include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/lambda.hcl"
  merge_strategy = "deep"
}

locals {
  env_inputs  = read_terragrunt_config(find_in_parent_folders("env.hcl")).inputs
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

inputs = {
  function_name = "${include.root.locals.name_prefix}-fn"

  memory_size = local.env_inputs.lambda_memory
  timeout     = local.env_inputs.lambda_timeout

  reserved_concurrent_executions = local.env_inputs.lambda_reserved_concurrency

  tags = include.root.locals.common_tags
}
