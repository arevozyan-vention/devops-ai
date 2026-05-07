# environments/dev/env.hcl — environment-specific values for dev.
# Read by both the root terragrunt.hcl (for env name + tags) and by every
# leaf terragrunt.hcl (for sizing / scaling overrides).

inputs = {
  env = "dev"

  # Networking
  az_suffixes        = ["a", "b"]
  vpc_cidr           = "10.10.0.0/16"
  public_subnets     = ["10.10.0.0/24", "10.10.1.0/24"]
  private_subnets    = ["10.10.10.0/24", "10.10.11.0/24"]
  single_nat_gateway = true

  # Compute
  # Sized for typical Node/Bun/Python apps with heavy boot (NestJS+TypeORM,
  # Next.js, Django, Rails). Earlier defaults of 256/512 OOM'd consistently
  # on real-world stacks — e.g. Activepieces hit 99% memory before the app
  # finished initializing, and self-heal's bump-doubled cap of 2048 was
  # still tight for Bun + PM2 + workers. 1024/4096 is roomy enough for
  # first-deploy success on most apps; the extra ~$15/month is worth not
  # burning 2-3 self-heal attempts on OOM in the typical case.
  ecs_cpu           = 1024
  ecs_memory        = 4096
  ecs_desired_count = 1

  # RDS
  rds_instance_class        = "db.t4g.micro"
  rds_allocated_storage     = 20
  rds_max_allocated_storage = 40
  rds_multi_az              = false
  rds_deletion_protection   = false
  rds_backup_retention      = 1
  rds_skip_final_snapshot   = true
  secrets_recovery_days     = 0

  # ALB
  alb_deletion_protection = false

  # App-level env var passed to the container (purely informational).
  app_env = "dev"
}
