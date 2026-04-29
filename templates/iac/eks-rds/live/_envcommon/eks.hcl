# _envcommon/eks.hcl — EKS managed cluster + a single managed node group.
# IRSA (OIDC provider) is enabled so service accounts can assume IAM roles.

terraform {
  source = "tfr:///terraform-aws-modules/eks/aws?version=20.31.6"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id          = "vpc-xxxxxxxx"
    private_subnets = ["subnet-aaaa", "subnet-bbbb"]
    public_subnets  = ["subnet-cccc", "subnet-dddd"]
  }
}

locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

inputs = {
  cluster_name    = ""  # filled in per-env
  cluster_version = local.inputs_yaml.cluster_version

  vpc_id     = dependency.vpc.outputs.vpc_id
  subnet_ids = dependency.vpc.outputs.private_subnets

  # Public endpoint enabled in dev for kubectl from operator laptop;
  # restricted in stage/prod via env.hcl.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  enable_irsa = true

  cluster_addons = {
    vpc-cni = { most_recent = true }
    coredns = { most_recent = true }
    kube-proxy = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true }
  }

  # Managed node group — sizing is overridden per-env via env.hcl.
  eks_managed_node_groups = {
    workers = {
      instance_types = ["t3.medium"]
      ami_type       = "AL2023_x86_64_STANDARD"

      min_size     = 1
      desired_size = 1
      max_size     = 2

      capacity_type = "ON_DEMAND"
    }
  }

  # Allow the operator's identity to administer the cluster on first apply.
  # The framework does not write any access entries by itself; the operator
  # must add their identity here or via `aws eks update-kubeconfig`.
  enable_cluster_creator_admin_permissions = true
}
