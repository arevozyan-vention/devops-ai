# _envcommon/redis.hcl — ElastiCache Redis as an opt-in skeleton extension.
#
# Pulls VPC subnets + CIDR from the vpc unit. Single-node by default (dev);
# overridable per-env (env.hcl can set num_cache_clusters > 1 for prod).

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/redis"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id              = "vpc-xxxxxxxx"
    vpc_cidr_block      = "10.0.0.0/16"
    elasticache_subnets = ["subnet-eeeee1", "subnet-eeeee2"]
    private_subnets     = ["subnet-aaaaa1", "subnet-aaaaa2"]
  }
}

locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

inputs = {
  vpc_id   = dependency.vpc.outputs.vpc_id
  vpc_cidr = dependency.vpc.outputs.vpc_cidr_block

  # Prefer dedicated `elasticache_subnets` if VPC module provisioned them,
  # else fall back to private_subnets. The bundled VPC module creates
  # elasticache_subnets when the corresponding input is set.
  subnet_ids = length(dependency.vpc.outputs.elasticache_subnets) > 0 ? dependency.vpc.outputs.elasticache_subnets : dependency.vpc.outputs.private_subnets
}
