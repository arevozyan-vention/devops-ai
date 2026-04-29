# Root Terragrunt configuration for the ecs-fargate-rds skeleton.
# Inherited by every leaf live/<env>/<component>/terragrunt.hcl via
#   include "root" { path = find_in_parent_folders(); expose = true }
#
# Responsibilities:
#   - Remote state backend (S3 with native lockfile (Terraform >= 1.10))
#   - AWS provider with default tags
#   - Project-wide locals exposed to leaves

locals {
  project_inputs = yamldecode(file(find_in_parent_folders("inputs.yaml")))

  project_name = local.project_inputs.project_name
  region       = local.project_inputs.region
  account_id   = local.project_inputs.account_id

  # Env is derived from the directory layout: live/<env>/<component>/
  # This avoids reading env.hcl from the root, which is invalid when the
  # root is processed without a leaf context.
  env = basename(dirname(get_terragrunt_dir()))

  name_prefix = "${local.project_name}-${local.env}"

  common_tags = {
    Project     = local.project_name
    Environment = local.env
    ManagedBy   = "terragrunt"
    Skeleton    = "lambda-apigw-dynamo"
  }
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket       = local.project_inputs.state_bucket
    key          = "${local.project_name}/${path_relative_to_include()}/terraform.tfstate"
    region       = local.region
    encrypt      = true
    use_lockfile = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region              = "${local.region}"
  allowed_account_ids = ["${local.account_id}"]
  default_tags { tags = ${jsonencode(local.common_tags)} }
}
EOF
}

# Force-overwrite each module's own versions.tf so our provider version
# constraint wins. `if_exists = "overwrite"` (not "overwrite_terragrunt")
# is intentional — community modules ship their own versions.tf which we
# need to replace, otherwise terraform errors on duplicate required_providers
# OR picks up too-loose version ranges (e.g. >= 5.0) and installs v6.x that
# breaks the modules pinned in this skeleton.
generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.70" }
    random = { source = "hashicorp/random", version = "~> 3.6"  }
  }
}
EOF
}


# NOTE: do not put `name_prefix` (or any other commonly-named variable like
# `name`, `tags`) in this top-level `inputs` block — terragrunt forwards root
# inputs to every module, and clashes with module variables of the same name
# (e.g. terraform-aws-modules/alb has `var.name_prefix` and conflicts with
# `var.name`). Leaves can still read these from `include.root.locals.*`.
inputs = {
  project_name = local.project_name
  region       = local.region
  env          = local.env
}
