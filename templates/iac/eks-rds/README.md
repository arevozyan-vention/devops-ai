# Skeleton: `eks-rds`

> A Terragrunt + Terraform skeleton for an application that needs Kubernetes
> on AWS — typically because the operator's org has standardized on Helm /
> kustomize / GitOps, or because the application is multi-service and benefits
> from K8s service discovery and pod-level autoscaling.

## When this fits

- The repo already contains Helm charts, kustomize overlays, or k8s manifests.
- You expect to run multiple co-located services (sidecars, fan-out workers).
- You need pod-level scaling, network policies, or admission controllers.
- The operator's team has Kubernetes ops experience (or accepts the cost
  of acquiring it).

## When this does **not** fit

- A single HTTP service with no Kubernetes affinity — `ecs-fargate-rds` is
  cheaper and simpler.
- Hard latency budgets where K8s control-plane variance matters — pick
  `ec2-asg-rds`.
- Mostly-event-driven workloads — `lambda-apigw-dynamo` is a better fit.

## What this provisions

| Layer | Resource | Module |
|---|---|---|
| Networking | VPC, public + private subnets, NAT | `terraform-aws-modules/vpc/aws` |
| Image registry | ECR repository (one per app) | `terraform-aws-modules/ecr/aws` |
| Secrets | Secrets Manager entries | `modules/secrets` (local) |
| Database | RDS Postgres | `terraform-aws-modules/rds/aws` |
| Cluster | EKS managed cluster + 1 managed node group | `terraform-aws-modules/eks/aws` |
| IAM (IRSA) | OIDC provider + service-account role for the app | `modules/app-iam` (local) |

The skeleton **does not** install the application chart, ingress controller,
or external-secrets driver. Those are out of scope: this is the AWS-side
infrastructure. The `deploy-app` step in the framework is responsible for
applying / upgrading the workload.

## Sizing per environment

| | dev | stage | prod |
|---|---|---|---|
| Node group instance type | `t3.medium` | `t3.large` | `m6i.large` |
| Node group min/desired/max | 1 / 1 / 2 | 2 / 2 / 4 | 3 / 3 / 8 |
| RDS instance class | `db.t4g.micro` | `db.t4g.small` | `db.t4g.medium` |
| RDS multi-AZ | no | no | yes |
| NAT gateways | 1 | 1 | 2 |
| EKS public endpoint | yes | restricted | restricted |

## Estimated monthly cost (AWS on-demand)

| | dev | prod |
|---|---|---|
| EKS control plane | ~$72 | ~$72 |
| Worker nodes | ~$32 | ~$220 |
| RDS Postgres | ~$15 | ~$70 |
| NAT | ~$33 | ~$66 |
| Data transfer | ~$5 | ~$30 |
| **Total** | **~$160** | **~$460** |

EKS adds a flat $72/mo control-plane charge regardless of size. Below that
threshold `ecs-fargate-rds` is meaningfully cheaper.

## Operator-provided inputs

The operator sets these at `select` time:

- `project_name`, `region`, `account_id`
- `cluster_version` (e.g. `"1.30"`)
- `domain_name` (optional — used by external-DNS later, not in this skeleton)
- `db_engine_version`, `db_name`, `db_master_username`

## What the AI step fills in

- Application secret names (Secrets Manager) — read from the overview
- Service-account name and namespace for IRSA (defaults to
  `app-sa` in the `default` namespace; override per app)

## What the operator does outside this skeleton

- Install ingress (NGINX, ALB controller) and any operators (cert-manager,
  external-DNS, external-secrets) as part of `deploy-app`.
- Populate the Secrets Manager entries.

## Layout

```
eks-rds/
├── README.md
├── inputs.yaml.tmpl
└── live/
    ├── root.hcl
    ├── _envcommon/  { vpc, ecr, secrets, rds-sg, rds, eks, app-iam }.hcl
    ├── dev/   { env.hcl, ... }
    ├── stage/ ...
    └── prod/  ...
```
