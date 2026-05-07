# Skeleton: `container-apps-postgres`

> A Terragrunt + Terraform skeleton for a containerized HTTP application
> running on **Azure Container Apps** (serverless containers, no Kubernetes
> management), with **Azure Database for PostgreSQL Flexible Server** for
> persistence. The Azure-side counterpart of the AWS `ecs-fargate-rds`
> skeleton — same opt-in extension catalog, same operator workflow, just
> Azure-native primitives underneath.

## When this fits

- The app is, or can be, packaged as a single OCI image.
- It speaks HTTP/HTTPS over a single TCP port.
- It uses Postgres (or any DB the operator can swap in via the `engine`
  variable in the postgres component).
- Required scale is roughly 1–10 always-on revisions. Bursty workloads also
  fit (Container Apps natively supports scale-to-zero via KEDA).

## When this does **not** fit

This is the only **Azure** skeleton the framework currently ships. If the app
falls into one of the categories below, you'll need to either adapt it to
Container Apps or extend the framework with a new skeleton:

- Stateful long-lived connections at scale (WebSocket fan-out across
  thousands of clients) — you may bump into the per-app concurrent
  connection limit; consider AKS with a custom controller.
- Pure event-driven workloads with no synchronous HTTP — likely better as
  Azure Functions + Service Bus.
- GPU / specialized hardware — Container Apps does not expose GPU SKUs;
  use AKS with a node pool.
- Multi-tenant Kubernetes already in the operator's org — extend the
  framework with an AKS skeleton.

The `recommend` / `assess` step will surface these mismatches under
"Fit Concerns" if it detects them in the source.

## What this provisions

| Layer | Azure resource | Module |
|---|---|---|
| Resource group | `azurerm_resource_group` | local `modules/identity` (creates RG too) |
| Networking | VNet, 2 delegated subnets (Container Apps, Postgres), NSG | direct `azurerm_*` in `vnet` envcommon |
| Image registry | One ACR (Premium not required), admin disabled, AcrPull role for the app identity | direct `azurerm_container_registry` |
| Identity | User-assigned managed identity, role assignments to ACR + Key Vault | local `modules/identity` |
| Secrets | Azure Key Vault + 3 empty secret entries (operator-provided values) | local `modules/secrets` |
| Database | Postgres Flexible Server (Burstable in dev, GP in prod), private endpoint via subnet delegation | direct `azurerm_postgresql_flexible_server` |
| DB firewall | Allow rule for Container Apps subnet (= AWS rds-sg) | local `modules/postgres-fw` |
| Compute platform | Container Apps Environment (= ECS cluster) | direct `azurerm_container_app_environment` |
| Compute workload | Container App (= ECS service + task definition) | direct `azurerm_container_app` |
| Ingress | Built-in into Container App. HTTPS automatic on `*.<region>.azurecontainerapps.io` | n/a (built-in) |

## Default sizing (dev)

| Resource | Default | Source |
|---|---|---|
| ACA workload profile | Consumption (scale-to-zero) | env.hcl |
| Container CPU/RAM | 0.5 vCPU / 1.0 GiB | env.hcl |
| Min/Max replicas | 1 / 3 | env.hcl |
| Postgres SKU | `B_Standard_B1ms` (Burstable, 1 vCPU, 2 GiB) | env.hcl |
| Postgres storage | 32 GiB | env.hcl |
| Postgres HA | disabled | env.hcl |
| Backups | 7 days, point-in-time | env.hcl |

Estimate: **~$45–60/month** dev (Container Apps consumption + Postgres
Burstable + ACR Basic + Key Vault). Cost grows with revisions kept warm.

## Opt-in extensions (`--include` at `select` time)

| Extension | What it adds | Approx dev cost |
|---|---|---|
| `redis` | Azure Cache for Redis (Basic C0, 250 MB) + injects `REDIS_URL` | +~$17/mo |
| `queue` | Azure Storage Queue + connection string injected | +<$1/mo |
| `frontend` | Second ACR repo + second Container App with path routing | +~$5–15/mo (depends on traffic) |
| `keycloak` | Container App for Keycloak with HTTPS path /auth | +~$15/mo |
| `custom-domain-https` | Custom DNS name + Azure-managed TLS cert binding | +<$1/mo (cert is free) |

Enable with comma-csv at `select` time:
```
./devops-ai.sh select <repo> --cloud azure --region eastus --env dev --include redis,queue
```

## Layout

```
container-apps-postgres/
├── README.md
├── inputs.yaml.tmpl
├── modules/                      # local TF modules (where direct azurerm fits poorly)
│   ├── identity/                 # managed identity + role assignments
│   ├── secrets/                  # Key Vault + N empty secret entries
│   ├── postgres-fw/              # Postgres firewall rule (= AWS rds-sg)
│   ├── redis/                    # Azure Cache for Redis (opt-in)
│   ├── queue/                    # Azure Storage Queue (opt-in)
│   ├── keycloak/                 # second Container App for Keycloak (opt-in)
│   └── custom-domain-https/      # custom domain + managed cert binding (opt-in)
└── environments/
    ├── root.hcl                  # azurerm provider, backend (Azure Storage), default tags
    ├── _envcommon/               # env-neutral wrapping for each unit
    │   ├── resource-group.hcl
    │   ├── vnet.hcl
    │   ├── identity.hcl
    │   ├── acr.hcl
    │   ├── acr-frontend.hcl
    │   ├── secrets.hcl
    │   ├── postgres.hcl
    │   ├── postgres-fw.hcl
    │   ├── container-apps-env.hcl
    │   ├── container-app.hcl
    │   ├── container-app-frontend.hcl
    │   ├── redis.hcl
    │   ├── queue.hcl
    │   ├── keycloak.hcl
    │   └── custom-domain-https.hcl
    └── dev/
        ├── env.hcl               # dev-specific sizing / counts
        ├── resource-group/
        ├── vnet/
        ├── identity/
        ├── acr/
        ├── acr-frontend/
        ├── secrets/
        ├── postgres/
        ├── postgres-fw/
        ├── container-apps-env/
        ├── container-app/
        ├── container-app-frontend/
        ├── redis/
        ├── queue/
        ├── keycloak/
        └── custom-domain-https/
```

## Mapping to the AWS skeleton

For operators familiar with `ecs-fargate-rds`:

| AWS unit | Azure unit | Notes |
|---|---|---|
| `vpc` | `resource-group` + `vnet` | RG is uniquely Azure (logical container); VNet is the network |
| `iam` | `identity` | User-assigned managed identity replaces task role + execution role |
| `secrets` | `secrets` | Key Vault entries instead of Secrets Manager |
| `rds` | `postgres` | Postgres Flexible Server |
| `rds-sg` | `postgres-fw` | Firewall rule on the server, scoped to the ACA subnet |
| `ecs-cluster` | `container-apps-env` | Container Apps Environment is the runtime context for all apps |
| `ecs-service` | `container-app` | Container App rolls out via revisions instead of task-def updates |
| `alb` | (built-in to Container App) | ACA includes ingress; no separate L7 to provision |
| `alb-https` | `custom-domain-https` | Custom domain + Azure-managed cert (free) |
| `ecr` | `acr` | Azure Container Registry |
| `ecr-frontend` | `acr-frontend` | Second ACR for frontend service |
| `ecs-service-frontend` | `container-app-frontend` | Second Container App, path-routed |
| `redis` | `redis` | Azure Cache for Redis instead of ElastiCache |
| `queue` | `queue` | Azure Storage Queue instead of SQS |
| `keycloak` | `keycloak` | Container App for Keycloak |

## State backend

Stored in an Azure Storage Account (RA-GRS) under a container per project,
configured in `environments/root.hcl`. The bootstrap step provisions the
account; subsequent units lock via Azure blob lease (analog of AWS
`use_lockfile=true`).

## Known caveats

- **Region availability of Container Apps**: not all Azure regions support
  Consumption workload profile. Use `eastus`, `westus3`, `westeurope`,
  `northeurope` as safe defaults. `recommend` will warn if the chosen
  region is one of the limited ones.
- **Postgres Flexible Server VNet integration**: requires subnet
  delegation to `Microsoft.DBforPostgreSQL/flexibleServers`. The `vnet`
  unit takes care of this.
- **First-time Container App start**: ACR pull + cold start on
  Consumption profile is ~30–90 seconds. Configure ingress probes with
  generous initial-delay.
