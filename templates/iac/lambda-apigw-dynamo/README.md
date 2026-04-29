# Skeleton: `lambda-apigw-dynamo`

> A Terragrunt + Terraform skeleton for an event-driven or low-traffic HTTP
> API that runs as a container-image Lambda function behind API Gateway HTTP
> API, with DynamoDB for persistence. Cheapest-by-far option for small
> services, especially those with bursty / sparse traffic.

## When this fits

- The application is a small HTTP API or worker that fits Lambda's execution
  model (≤15 minutes per invocation, no long-lived connections).
- Persistence is key/value or simple document-shaped — DynamoDB suffices.
- Total monthly request volume is below ~5M; above that, ECS/EKS economics
  start to win.
- The repo can be packaged as a container image (Lambda container support
  is required by this skeleton).

## When this does **not** fit

- Long-lived TCP/WebSocket connections.
- Strong relational schema requirements — DynamoDB is not a SQL database.
- Latency-sensitive synchronous APIs that can't tolerate cold starts.
- Heavy CPU/memory workloads (Lambda hard limits at 10 GB / 6 vCPU).

## What this provisions

| Layer | Resource | Module |
|---|---|---|
| Image registry | ECR repository | `terraform-aws-modules/ecr/aws` |
| Secrets | Secrets Manager entries | `modules/secrets` (local) |
| Persistence | DynamoDB table (on-demand by default) | `terraform-aws-modules/dynamodb-table/aws` |
| Compute | Lambda function (container image) | `terraform-aws-modules/lambda/aws` |
| Ingress | API Gateway HTTP API + default stage | `terraform-aws-modules/apigateway-v2/aws` |
| IAM | Lambda execution role with secrets / dynamo access | inline (in lambda module) |

No VPC by default. If the function needs to reach private RDS or a corporate
network, add `vpc_subnet_ids` and `vpc_security_group_ids` inputs to the
`lambda` component (it's a one-line change).

## Sizing per environment

| | dev | stage | prod |
|---|---|---|---|
| Lambda memory | 512 MB | 1024 MB | 2048 MB |
| Lambda reserved concurrency | none (pool default) | none | 50 |
| DynamoDB billing mode | PAY_PER_REQUEST | PAY_PER_REQUEST | PAY_PER_REQUEST |
| DynamoDB point-in-time recovery | off | on | on |

## Estimated monthly cost (very rough)

| | dev | prod (1M req/mo) |
|---|---|---|
| Lambda invocations | <$1 | ~$5 |
| Lambda compute | <$1 | ~$10 |
| API Gateway HTTP | <$1 | ~$1 |
| DynamoDB on-demand | <$1 | ~$5 |
| CloudWatch logs | <$1 | ~$3 |
| **Total** | **<$5** | **~$25** |

This is the cheapest option in the catalog by an order of magnitude. It also
means the operator pays nothing when traffic is zero.

## Operator-provided inputs

- `project_name`, `region`, `account_id`
- `function_handler` — the entrypoint inside the container image (default
  `app.handler` for most runtimes; container Lambdas usually ignore this)
- `dynamo_partition_key` — primary partition key name (default `pk`)
- `dynamo_sort_key` — optional sort key

## What the AI step fills in

- Required env vars on the Lambda (from the overview)
- Secret references (Secrets Manager ARNs)
- Whether a sort key is needed (looks at the data model in the overview)

## Layout

```
lambda-apigw-dynamo/
├── README.md
├── inputs.yaml.tmpl
└── live/
    ├── root.hcl
    ├── _envcommon/  { ecr, secrets, dynamo, lambda, apigw }.hcl
    ├── dev/   { env.hcl, ... }
    ├── stage/ ...
    └── prod/  ...
```
