include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/eks.hcl"
  merge_strategy = "deep"
}

locals {
  env_inputs = read_terragrunt_config(find_in_parent_folders("env.hcl")).inputs
}

inputs = {
  cluster_name = "${include.root.locals.name_prefix}-cluster"

  cluster_endpoint_public_access = local.env_inputs.eks_endpoint_public_access

  eks_managed_node_groups = {
    workers = {
      instance_types = local.env_inputs.eks_instance_types
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = local.env_inputs.eks_min_size
      desired_size   = local.env_inputs.eks_desired_size
      max_size       = local.env_inputs.eks_max_size
      capacity_type  = "ON_DEMAND"
    }
  }

  tags = include.root.locals.common_tags
}
