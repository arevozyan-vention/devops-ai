# live/prod/env.hcl

inputs = {
  env = "prod"

  az_suffixes      = ["a", "b"]
  vpc_cidr         = "10.90.0.0/16"
  public_subnets   = ["10.90.0.0/24",  "10.90.1.0/24"]
  private_subnets  = ["10.90.10.0/24", "10.90.11.0/24"]
  single_nat_gateway = false

  asg_instance_type  = "m6i.large"
  asg_min_size       = 3
  asg_desired_size   = 3
  asg_max_size       = 8

  rds_instance_class        = "db.t4g.medium"
  rds_allocated_storage     = 50
  rds_max_allocated_storage = 500
  rds_multi_az              = true
  rds_deletion_protection   = true
  rds_backup_retention      = 14
  rds_skip_final_snapshot   = false
  secrets_recovery_days     = 14

  alb_deletion_protection = true
}
