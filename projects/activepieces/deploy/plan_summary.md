# Plan summary — activepieces / dev / westus3  (cloud=azure)

## Identity
- Subscription: e36fefa8-d62a-405e-8dd5-4358e56b8c2f
- Tenant:       bd65ee34-dec1-44cb-ac8c-39f3fce9e101
- Generated:    2026-05-07T14:14:22Z

## Architecture (ASCII diagram — text only, no images)

```
                              Internet
                                 │ https :443
                ┌────────────────▼─────────────────┐
                │ Container App                    │  (PLAN FAILED — see note)
                │ [container-app] (port 8080)      │  pulls from ACR
                │ identity: user-assigned          │
                └───┬────────┬────────┬────────┬───┘
                    │        │        │        │
            ┌───────▼──┐ ┌───▼─────┐ ┌▼─────┐ ┌▼──────────────┐
            │ Key Vault│ │ ACR     │ │ UAMI │ │ Container Apps│
            │ [secrets]│ │ [acr]   │ │[ident│ │ Environment   │
            │  std SKU │ │  Basic  │ │ ity] │ │ [container-   │
            │ 3 secret │ │         │ │ +RA  │ │  apps-env]    │
            │ placehold│ │         │ │ ACR  │ │ + LA Workspace│
            │ + writer │ │         │ │ Pull │ │  (PerGB2018)  │
            │   RA     │ │         │ │ + KV │ │               │
            └──────────┘ └─────────┘ │ Sec  │ └───────┬───────┘
                                     │ User │         │
                                     └──────┘         │
                                                      │ aca-subnet
                                                      ▼ (delegated)
                                          ┌──────────────────────────┐
                                          │ VNet [vnet] 10.30.0.0/16 │
                                          │  • aca-subnet 10.30.0/23 │
                                          │     deleg Microsoft.App  │
                                          │  • postgres-subnet       │
                                          │     10.30.4.0/24 deleg   │
                                          │     DBforPostgreSQL/flex │
                                          │  • Private DNS zone:     │
                                          │    private.postgres...   │
                                          │  • DNS zone vnet link    │
                                          └────────────┬─────────────┘
                                                       │
                                          ┌────────────▼─────────────┐
                                          │ Postgres Flexible Server │
                                          │ [postgres]  :5432 v16    │
                                          │ sku B_Standard_B1ms      │
                                          │  + appdb database        │
                                          │  + random_password admin │
                                          └────────────┬─────────────┘
                                                       │
                                          ┌────────────▼─────────────┐
                                          │ Firewall rules           │
                                          │ [postgres-fw] (no change)│
                                          └──────────────────────────┘

  Resource Group [resource-group] activepieces-dev-rg (westus3)
    contains all resources above.

  NOTE: [container-app] terraform plan failed with
   `expected 2 or 3 path segments, found 1 segment(s) in ""`
   on `azurerm_container_app.this` — mock dependency outputs
   resolve container_app_environment_id to "" before
   container-apps-env exists. Resource is not yet plan-validated.
```

## Resource map

| Unit | Type | Name | Where | Why |
|------|------|------|-------|-----|
| acr | azurerm_container_registry | this | RG, westus3, sku=Basic | Container image registry for backend |
| container-apps-env | azurerm_container_app_environment | this | RG, westus3, aca-subnet | Managed runtime for Container Apps |
| container-apps-env | azurerm_log_analytics_workspace | this | RG, westus3, sku=PerGB2018 | Log sink for ACA env (30d retention) |
| identity | azurerm_role_assignment | acr_pull | ACR scope | Grants UAMI AcrPull on registry |
| identity | azurerm_role_assignment | kv_secrets_user | Key Vault scope | Grants UAMI Key Vault Secrets User |
| identity | azurerm_user_assigned_identity | this | RG, westus3 | Workload identity for Container App |
| postgres | azurerm_postgresql_flexible_server | this | RG, westus3, sku=B_Standard_B1ms, v16, postgres-subnet | Primary OLTP database |
| postgres | azurerm_postgresql_flexible_server_database | appdb | postgres flexible server | Application database |
| postgres | random_password | admin | (terraform state) | Generated admin password |
| resource-group | azurerm_resource_group | this | westus3 | Top-level container for env |
| secrets | azurerm_key_vault | this | RG, westus3, sku=standard | Secret store for app + admin pwd |
| secrets | azurerm_key_vault_secret | placeholder (#1) | Key Vault | Bootstrap secret slot |
| secrets | azurerm_key_vault_secret | placeholder (#2) | Key Vault | Bootstrap secret slot |
| secrets | azurerm_key_vault_secret | placeholder (#3) | Key Vault | Bootstrap secret slot |
| secrets | azurerm_role_assignment | bootstrap_writer | Key Vault scope | Grants deployer Secrets Officer for bootstrap |
| vnet | azurerm_private_dns_zone | postgres | RG | private.postgres.database.azure.com zone |
| vnet | azurerm_private_dns_zone_virtual_network_link | postgres | private DNS zone ↔ vnet | Resolves Postgres FQDN inside VNet |
| vnet | azurerm_subnet | container_apps | vnet 10.30.0.0/23, deleg Microsoft.App/environments | Subnet for Container Apps env |
| vnet | azurerm_subnet | postgres | vnet 10.30.4.0/24, deleg DBforPostgreSQL/flexibleServers | Subnet for Postgres flexible server |
| vnet | azurerm_virtual_network | this | RG, westus3, 10.30.0.0/16 | VNet hosting ACA + Postgres subnets |

## Per-unit counts

| Unit | + add | ~ change | - destroy |
|------|-------|----------|-----------|
| acr | 1 | 0 | 0 |
| container-app | FAILED | FAILED | FAILED |
| container-apps-env | 2 | 0 | 0 |
| identity | 3 | 0 | 0 |
| postgres | 3 | 0 | 0 |
| postgres-fw | 0 | 0 | 0 |
| resource-group | 1 | 0 | 0 |
| secrets | 5 | 0 | 0 |
| vnet | 5 | 0 | 0 |

## Totals
- To add: 20
- To change: 0
- To destroy: 0

## Deferred to apply
(none — cloud=azure, no greenfield exclusions configured)
