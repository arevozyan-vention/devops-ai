# live/stage/env.hcl

inputs = {
  env = "stage"

  az_suffixes      = ["a", "b"]
  vpc_cidr         = "10.80.0.0/16"
  public_subnets   = ["10.80.0.0/24",  "10.80.1.0/24"]
  private_subnets  = ["10.80.10.0/24", "10.80.11.0/24"]
  single_nat_gateway = true

  asg_instance_type  = "t3.medium"
  asg_min_size       = 2
  asg_desired_size   = 2
  asg_max_size       = 4

  rds_instance_class        = "db.t4g.small"
  rds_allocated_storage     = 20
  rds_max_allocated_storage = 100
  rds_multi_az              = false
  rds_deletion_protection   = false
  rds_backup_retention      = 7
  rds_skip_final_snapshot   = false
  secrets_recovery_days     = 7

  alb_deletion_protection = false
}
