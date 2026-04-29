# _envcommon/ecs-cluster.hcl — Fargate cluster only. Services are defined in
# the ecs-service component.

terraform {
  source = "tfr:///terraform-aws-modules/ecs/aws?version=5.11.4"
}

inputs = {
  cluster_name = "" # filled in per-env

  cluster_settings = [
    { name = "containerInsights", value = "enabled" }
  ]

  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 100
        base   = 1
      }
    }
    FARGATE_SPOT = {
      default_capacity_provider_strategy = {
        weight = 0
      }
    }
  }

  # The service is provisioned in a separate Terragrunt unit so cluster and
  # service can be applied independently (faster iteration on app deploys).
  services = {}
}
