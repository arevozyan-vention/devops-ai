include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/vpc.hcl"
  merge_strategy = "deep"
}

locals {
  env_inputs = read_terragrunt_config(find_in_parent_folders("env.hcl")).inputs
  region     = yamldecode(file(find_in_parent_folders("inputs.yaml"))).region
}

inputs = {
  name = "${include.root.locals.name_prefix}-vpc"
  azs  = [for s in local.env_inputs.az_suffixes : "${local.region}${s}"]

  cidr            = local.env_inputs.vpc_cidr
  public_subnets  = local.env_inputs.public_subnets
  private_subnets = local.env_inputs.private_subnets

  single_nat_gateway     = local.env_inputs.single_nat_gateway
  one_nat_gateway_per_az = !local.env_inputs.single_nat_gateway

  tags = include.root.locals.common_tags
}
