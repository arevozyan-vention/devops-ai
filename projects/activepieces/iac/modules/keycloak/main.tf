# Keycloak as a Container App, path-routed at /auth on the same default
# ingress hostname as the main app. The Keycloak admin realm requires HTTPS;
# Container Apps' built-in *.azurecontainerapps.io subdomain is HTTPS by
# default, so this works out of the box without the custom-domain-https
# extension.
#
# Storage: a separate small Postgres DB for Keycloak's own state. Reuses the
# main postgres server (cheaper than a second one); creates a `keycloak` DB
# alongside the app DB.

resource "azurerm_postgresql_flexible_server_database" "keycloak" {
  name      = "keycloak"
  server_id = var.postgres_server_id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

resource "random_password" "kc_admin" {
  length  = 24
  special = true
}

resource "azurerm_container_app" "keycloak" {
  name                         = "${var.name_prefix}-kc"
  container_app_environment_id = var.container_app_environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "keycloak"
      image  = "quay.io/keycloak/keycloak:24.0"
      cpu    = 1.0
      memory = "2.0Gi"

      command = ["/opt/keycloak/bin/kc.sh"]
      args    = ["start", "--http-enabled=true", "--proxy=edge", "--hostname-strict=false"]

      env {
        name  = "KC_DB"
        value = "postgres"
      }
      env {
        name  = "KC_DB_URL"
        value = "jdbc:postgresql://${var.postgres_fqdn}:5432/keycloak?sslmode=require"
      }
      env {
        name  = "KC_DB_USERNAME"
        value = var.postgres_admin_username
      }
      env {
        name        = "KC_DB_PASSWORD"
        secret_name = "kc-db-password"
      }
      env {
        name  = "KEYCLOAK_ADMIN"
        value = "kcadmin"
      }
      env {
        name        = "KEYCLOAK_ADMIN_PASSWORD"
        secret_name = "kc-admin-password"
      }
      env {
        name  = "KC_PROXY_HEADERS"
        value = "xforwarded"
      }

      readiness_probe {
        path             = "/health/ready"
        port             = 8080
        transport        = "HTTP"
        interval_seconds = 10
        timeout          = 5
      }
    }
  }

  secret {
    name  = "kc-db-password"
    value = var.postgres_admin_password
  }
  secret {
    name  = "kc-admin-password"
    value = random_password.kc_admin.result
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "http" # azurerm 4.x: "http" | "http2" | "tcp"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}
