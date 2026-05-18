# Root Terragrunt configuration for the container-apps-postgres skeleton.
# Inherited by every leaf environments/<env>/<component>/terragrunt.hcl via
#   include "root" { path = find_in_parent_folders(); expose = true }
#
# Responsibilities:
#   - Remote state backend (Azure Storage with blob-lease locking)
#   - azurerm provider with default tags
#   - Project-wide locals exposed to leaves

locals {
  project_inputs = yamldecode(file(find_in_parent_folders("inputs.yaml")))

  project_name    = local.project_inputs.project_name
  region          = local.project_inputs.region
  subscription_id = local.project_inputs.subscription_id
  tenant_id       = local.project_inputs.tenant_id

  # Env is derived from the directory layout: environments/<env>/<component>/
  env = basename(dirname(get_terragrunt_dir()))

  name_prefix = "${local.project_name}-${local.env}"

  # Resource group name is reused by every unit. Centralized here so leaves
  # don't have to know the convention.
  resource_group_name = "${local.name_prefix}-rg"

  common_tags = {
    project     = local.project_name
    environment = local.env
    managedby   = "terragrunt"
    skeleton    = "container-apps-postgres"
  }
}

# Azure Storage state backend. Uses blob lease for state locking
# (azurerm provider builds this in — no separate lock table needed).
remote_state {
  backend = "azurerm"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    resource_group_name  = local.project_inputs.state_storage_account != "" ? "${local.project_inputs.state_storage_account}-rg" : "${local.name_prefix}-tfstate-rg"
    storage_account_name = local.project_inputs.state_storage_account
    container_name       = local.project_inputs.state_container
    key                  = "${local.project_name}/${path_relative_to_include()}/terraform.tfstate"
    use_azuread_auth     = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
  subscription_id = "${local.subscription_id}"
  tenant_id       = "${local.tenant_id}"
}

provider "azapi" {}
EOF
}

# Force-overwrite each module's versions.tf so our provider version wins.
# `if_exists = "overwrite"` (not "overwrite_terragrunt") is intentional —
# external modules ship their own required_providers blocks that we need to
# replace, otherwise terraform errors on duplicate declarations or picks up
# loose version ranges that break the skeleton.
generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    # Strict pins. The Dockerfile prebake installs the SAME exact versions
    # into the plugin cache; if these drift apart, a project's
    # `.terraform.lock.hcl` ends up wanting a version that isn't in the
    # cache and apply fails with "no package for X cached". Bump in BOTH
    # places together (Dockerfile prebake + every root.hcl).
    azurerm = { source = "hashicorp/azurerm", version = "= 4.72.0" }
    azapi   = { source = "Azure/azapi",       version = "= 2.9.0"  }
    random  = { source = "hashicorp/random",  version = "= 3.8.1"  }
    tls     = { source = "hashicorp/tls",     version = "= 4.2.1"  }
  }
}
EOF
}

# Common inputs forwarded to every leaf. Don't put module-conflict-prone
# names like `name`, `tags`, `name_prefix` here — leaves should reach them
# via `include.root.locals.*` instead, to avoid collisions with variables of
# the same name in upstream modules.
inputs = {
  project_name        = local.project_name
  region              = local.region
  env                 = local.env
  subscription_id     = local.subscription_id
  tenant_id           = local.tenant_id
  resource_group_name = local.resource_group_name
}
