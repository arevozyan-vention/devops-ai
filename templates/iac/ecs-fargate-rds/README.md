# Skeleton: `ecs-fargate-rds`

> A Terragrunt + Terraform skeleton for a containerized HTTP application
> running on AWS ECS Fargate, fronted by an Application Load Balancer, with
> PostgreSQL on RDS for persistence. Designed to be the **default choice** for
> a typical web app or HTTP API that has a `Dockerfile` and a SQL database.

## When this fits

- The app is, or can be, packaged as a single OCI image.
- It speaks HTTP/HTTPS over a single TCP port.
- It uses Postgres (or any DB the operator can swap in via the `engine`
  variable in the RDS component).
- Required scale is roughly 1–10 always-on tasks. Bursty workloads also fit.

## When this does **not** fit

- Stateful long-lived connections at scale (WebSocket fan-out across
  thousands of clients) — consider `eks-rds`.
- Pure event-driven workloads with no synchronous HTTP — consider
  `lambda-sqs`.
- GPU / specialized hardware — consider `ec2-asg-rds` with a custom AMI.
- Multi-tenant Kubernetes already in the operator's org — use `eks-rds`.

## What this provisions

| Layer | AWS resource | Module |
|---|---|---|
| Networking | VPC, 2× public + 2× private subnets, IGW, single NAT | `terraform-aws-modules/vpc/aws` |
| Image registry | One ECR repository, lifecycle policy keeps last 30 images | `terraform-aws-modules/ecr/aws` |
| Secrets | Secrets Manager entries; values are operator-provided | `aws_secretsmanager_secret` |
| Database | RDS Postgres (single-AZ in dev, multi-AZ in prod) | `terraform-aws-modules/rds/aws` |
| Compute | ECS Fargate cluster | `terraform-aws-modules/ecs/aws` |
| Compute | ECS service + task definition (one container) | `terraform-aws-modules/ecs/aws//modules/service` |
| Ingress | Application Load Balancer, HTTP→HTTPS redirect, ACM-issued cert | `terraform-aws-modules/alb/aws` |
| Observability | CloudWatch log group per env | inline |
| IAM | Task execution role + task role with least-privilege policies | inline |

## Sizing per environment

| | dev | stage | prod |
|---|---|---|---|
| ECS task count | 1 | 2 | 3 |
| ECS task CPU/memory | 256 / 512 | 512 / 1024 | 1024 / 2048 |
| RDS instance class | `db.t4g.micro` | `db.t4g.small` | `db.t4g.medium` |
| RDS multi-AZ | no | no | yes |
| RDS backup retention | 1 day | 7 days | 14 days |
| NAT gateways | 1 | 1 | 2 |

These defaults live in `environments/<env>/env.hcl` and are easy to edit before deploy.

## Estimated monthly cost (AWS on-demand list, no Savings Plan)

| | dev | prod |
|---|---|---|
| ECS Fargate | ~$10 | ~$80 |
| RDS Postgres | ~$15 | ~$70 |
| ALB | ~$18 | ~$22 |
| NAT gateway(s) | ~$33 | ~$66 |
| Data transfer (rough) | ~$5 | ~$30 |
| CloudWatch logs | ~$2 | ~$15 |
| **Total** | **~$80–90** | **~$280–320** |

Numbers swing with traffic. The two biggest line items in a quiet env are
**NAT** and **ALB** — neither scales with workload.

## Operator-provided inputs

The framework asks for these at `select` time and writes them into
`projects/<repo>/iac/inputs.yaml`:

- `project_name` — short, lowercase, used in resource names
- `region` — AWS region (e.g. `us-east-1`)
- `account_id` — 12-digit AWS account id
- `container_port` — port the app listens on inside the container
- `domain_name` — optional. If set, an ACM cert is issued and the ALB
  serves HTTPS on it. If empty, only HTTP is exposed (dev only).
- `health_check_path` — defaults to `/health`
- `db_name`, `db_master_username` — RDS application database

What the **AI step** then fills in:

- The `environment` block on the ECS task (env vars from the overview).
- The `secrets` block (Secrets Manager ARNs for sensitive vars).
- DB engine version (matched to what the overview reports).
- Health-check path if the overview specifies a non-default one.

What the operator must do **outside** this skeleton:

- Populate the Secrets Manager entries with real values after the first
  apply (the framework provisions empty secrets; it never writes values).
- Point DNS at the ALB if a domain is used.

## Layout

```
ecs-fargate-rds/
├── README.md                          (this file — read by `recommend`)
├── inputs.yaml.tmpl                   (variable contract; rendered into projects/<repo>/iac/inputs.yaml)
└── environments/
    ├── terragrunt.hcl                 (root: remote state + provider config)
    ├── _envcommon/                    (per-component shared HCL)
    │   ├── vpc.hcl
    │   ├── ecr.hcl
    │   ├── secrets.hcl
    │   ├── rds.hcl
    │   ├── ecs-cluster.hcl
    │   ├── alb.hcl
    │   ├── iam.hcl
    │   └── ecs-service.hcl
    ├── dev/   { env.hcl, vpc/, ecr/, secrets/, rds/, ecs-cluster/, alb/, iam/, ecs-service/ }
    ├── stage/ (same)
    └── prod/  (same)
```

Each leaf `terragrunt.hcl` includes its `_envcommon/<component>.hcl` and
adds env-specific overrides via `env.hcl`. Apply order is enforced through
explicit `dependency` blocks; `terragrunt run --all apply` figures it out.
