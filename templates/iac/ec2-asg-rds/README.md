# Skeleton: `ec2-asg-rds`

> A Terragrunt + Terraform skeleton for an application that runs as a plain
> process on EC2 instances behind an Application Load Balancer, with RDS
> Postgres for persistence. The "boring" choice — no containers required —
> for legacy services, AMI-based deploys, or workloads that pin to specific
> hardware.

## When this fits

- The app runs as a systemd service on a plain Linux box (no Docker required).
- You need a **specific AMI** (CIS-hardened, GPU drivers, kernel tuning).
- You want a single deploy primitive that operations already understands
  — a launch template + ASG.
- Container images are not built and there's no good reason to introduce them.

## When this does **not** fit

- You already containerize. `ecs-fargate-rds` is simpler.
- You need fast scale-out (ASG warm-up takes minutes; ECS/EKS is faster).
- The app is stateful in-process (sessions, in-memory caches). ASG instance
  rotation will lose state.

## What this provisions

| Layer | Resource | Module |
|---|---|---|
| Networking | VPC, public + private subnets, NAT | `terraform-aws-modules/vpc/aws` |
| Secrets | Secrets Manager entries | `modules/secrets` (local) |
| Database | RDS Postgres | `terraform-aws-modules/rds/aws` |
| Compute | EC2 launch template + Auto Scaling Group | `terraform-aws-modules/autoscaling/aws` |
| Ingress | Application Load Balancer | `terraform-aws-modules/alb/aws` |
| IAM | EC2 instance profile (read secrets, write logs) | `modules/instance-iam` (local) |

The launch template uses a basic **Amazon Linux 2023** AMI by default
(`amazon-linux-2023` SSM parameter). User-data:

- Installs `awslogs` and CloudWatch Agent
- Pulls the application artifact from S3 (operator-provided bucket)
- Starts a `systemd` service named after `project_name`

The artifact pull is a placeholder — the operator wires their own deploy
mechanism (CodeDeploy, Ansible, raw `aws s3 cp + tar -x`). The framework's
`deploy-app` step uploads the artifact to S3 and triggers an ASG instance
refresh.

## Sizing per environment

| | dev | stage | prod |
|---|---|---|---|
| Instance type | `t3.small` | `t3.medium` | `m6i.large` |
| ASG min/desired/max | 1 / 1 / 2 | 2 / 2 / 4 | 3 / 3 / 8 |
| RDS instance class | `db.t4g.micro` | `db.t4g.small` | `db.t4g.medium` |
| RDS multi-AZ | no | no | yes |
| NAT gateways | 1 | 1 | 2 |

## Estimated monthly cost

| | dev | prod |
|---|---|---|
| EC2 (1× t3.small / 3× m6i.large) | ~$15 | ~$210 |
| ALB | ~$18 | ~$22 |
| RDS Postgres | ~$15 | ~$70 |
| NAT | ~$33 | ~$66 |
| Data transfer / logs | ~$10 | ~$40 |
| **Total** | **~$90** | **~$410** |

## Operator-provided inputs

- `project_name`, `region`, `account_id`
- `app_port` — the port the app listens on
- `health_check_path` — defaults to `/health`
- `artifact_bucket` — S3 bucket the launch template's user-data pulls from
- `db_engine_version`, `db_name`, `db_master_username`

## What the AI step fills in

- The systemd unit's `ExecStart` command (read from the overview)
- Required env vars / secret references in the launch template's user-data
- AMI choice override if the overview demands a non-default image

## Layout

```
ec2-asg-rds/
├── README.md
├── inputs.yaml.tmpl
└── live/
    ├── root.hcl
    ├── _envcommon/  { vpc, secrets, rds-sg, rds, alb, asg, instance-iam }.hcl
    ├── dev/   { env.hcl, ... }
    ├── stage/ ...
    └── prod/  ...
```
