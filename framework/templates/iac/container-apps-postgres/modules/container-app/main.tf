# A single Container App. Analog of ECS service + task definition combined —
# Container Apps does revisions automatically, so deploy-app just calls
# `az containerapp update --image ...` and ACA rolls a new revision.
#
# Image: starts with a placeholder (mcr.microsoft.com/.../helloworld) so the
# first apply succeeds even before deploy-app pushes a real image. deploy-app
# then updates it via az cli (lifecycle.ignore_changes prevents drift).

resource "azurerm_container_app" "this" {
  name                         = "${var.name_prefix}${var.suffix == "" ? "" : "-${var.suffix}"}"
  container_app_environment_id = var.container_app_environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single" # alt: "Multiple" + traffic splitting
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.identity_id
  }

  # Map Key Vault secret URIs into Container App secrets (referenced by env vars).
  dynamic "secret" {
    for_each = var.kv_secret_uris
    content {
      name                = lower(replace(secret.key, "_", "-"))
      key_vault_secret_id = secret.value
      identity            = var.identity_id
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = var.container_name
      image  = var.image # placeholder on first apply; deploy-app updates
      cpu    = var.cpu
      memory = "${var.memory_gib}Gi"

      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.kv_secret_uris
        content {
          name        = env.key
          secret_name = lower(replace(env.key, "_", "-"))
        }
      }

      dynamic "liveness_probe" {
        for_each = var.health_check_path == "" ? [] : [1]
        content {
          path                    = var.health_check_path
          port                    = var.target_port
          transport               = "HTTP"
          initial_delay           = 30
          interval_seconds        = 10
          timeout                 = 5
          failure_count_threshold = 3
        }
      }

      dynamic "readiness_probe" {
        for_each = var.health_check_path == "" ? [] : [1]
        content {
          path                    = var.health_check_path
          port                    = var.target_port
          transport               = "HTTP"
          interval_seconds        = 5
          timeout                 = 3
          failure_count_threshold = 3
        }
      }

      dynamic "startup_probe" {
        for_each = var.health_check_path == "" ? [] : [1]
        content {
          path             = var.health_check_path
          port             = var.target_port
          transport        = "HTTP"
          # azurerm 4.x: interval_seconds 1..240, failure_count_threshold 1..10.
          # 15s × 10 attempts = ~150s cold-start budget; enough for typical
          # Node/bun/Python apps but not absurd. Bump only if your container
          # genuinely needs longer (rare on Container Apps Consumption).
          interval_seconds        = 15
          timeout                 = 5
          failure_count_threshold = 10
        }
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = var.target_port
    # azurerm 4.x ingress.transport accepts: "http" | "http2" | "tcp"
    # ("auto" worked in 3.x but is no longer valid). HTTP is the right
    # default for typical web apps; the operator can flip to http2 if the
    # app speaks h2c, or tcp for non-HTTP workloads.
    transport                  = "http"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  # The image is updated by deploy-app via `az containerapp update --image`.
  # Don't drift on subsequent terraform applies.
  lifecycle {
    ignore_changes = [
      template[0].container[0].image,
    ]
  }
}
