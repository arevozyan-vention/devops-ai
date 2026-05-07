# Bind a custom domain to the main Container App with an Azure-managed
# certificate. Requires the operator to have already pointed a CNAME at
# <app-fqdn> and a TXT record `asuid.<domain>` at the app's verification id
# (Container Apps issues these via portal or `az containerapp hostname add`).
#
# This is the minimal-effort HTTPS setup. For multi-tenant or advanced
# routing, put Azure Front Door in front of the Container App.

resource "azurerm_container_app_custom_domain" "this" {
  name             = var.custom_domain
  container_app_id = var.container_app_id

  # Managed cert — Azure provisions and renews automatically.
  certificate_binding_type = "SniEnabled"
  # No `container_app_environment_certificate_id` → use a free managed cert
  # (still requires the asuid TXT verification record on operator's DNS).
}
