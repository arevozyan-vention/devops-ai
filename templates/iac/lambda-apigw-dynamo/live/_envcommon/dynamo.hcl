# _envcommon/dynamo.hcl — single DynamoDB table, on-demand billing.

terraform {
  source = "tfr:///terraform-aws-modules/dynamodb-table/aws?version=4.3.0"
}

locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))

  pk_name = local.inputs_yaml.dynamo_partition_key
  sk_name = local.inputs_yaml.dynamo_sort_key

  # Build the attribute list conditionally (always include the partition key,
  # add the sort key when its name is non-empty).
  attributes = concat(
    [{ name = local.pk_name, type = "S" }],
    local.sk_name == "" ? [] : [{ name = local.sk_name, type = "S" }],
  )
}

inputs = {
  name         = ""  # filled per-env
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = local.pk_name
  range_key = local.sk_name == "" ? null : local.sk_name

  attributes = local.attributes

  point_in_time_recovery_enabled = false  # flipped on in stage/prod
  server_side_encryption_enabled = true
}
