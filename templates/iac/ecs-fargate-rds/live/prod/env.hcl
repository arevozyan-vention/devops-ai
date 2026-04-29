# live/prod/env.hcl

inputs = {
  env = "prod"

  az_suffixes        = ["a", "b"]
  vpc_cidr           = "10.30.0.0/16"
  public_subnets     = ["10.30.0.0/24", "10.30.1.0/24"]
  private_subnets    = ["10.30.10.0/24", "10.30.11.0/24"]
  single_nat_gateway = false # one NAT per AZ for HA

  ecs_cpu           = 1024
  ecs_memory        = 2048
  ecs_desired_count = 3

  rds_instance_class        = "db.t4g.medium"
  rds_allocated_storage     = 50
  rds_max_allocated_storage = 500
  rds_multi_az              = true
  rds_deletion_protection   = true
  rds_backup_retention      = 14
  rds_skip_final_snapshot   = false
  secrets_recovery_days     = 14

  alb_deletion_protection = true

  app_env = "prod"
}
