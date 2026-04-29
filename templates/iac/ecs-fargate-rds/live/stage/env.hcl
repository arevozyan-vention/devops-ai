# live/stage/env.hcl

inputs = {
  env = "stage"

  az_suffixes        = ["a", "b"]
  vpc_cidr           = "10.20.0.0/16"
  public_subnets     = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnets    = ["10.20.10.0/24", "10.20.11.0/24"]
  single_nat_gateway = true

  ecs_cpu           = 512
  ecs_memory        = 1024
  ecs_desired_count = 2

  rds_instance_class        = "db.t4g.small"
  rds_allocated_storage     = 20
  rds_max_allocated_storage = 100
  rds_multi_az              = false
  rds_deletion_protection   = false
  rds_backup_retention      = 7
  rds_skip_final_snapshot   = false
  secrets_recovery_days     = 7

  alb_deletion_protection = false

  app_env = "stage"
}
