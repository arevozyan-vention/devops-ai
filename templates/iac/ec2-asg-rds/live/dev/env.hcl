# live/dev/env.hcl

inputs = {
  env = "dev"

  az_suffixes      = ["a", "b"]
  vpc_cidr         = "10.70.0.0/16"
  public_subnets   = ["10.70.0.0/24",  "10.70.1.0/24"]
  private_subnets  = ["10.70.10.0/24", "10.70.11.0/24"]
  single_nat_gateway = true

  asg_instance_type  = "t3.small"
  asg_min_size       = 1
  asg_desired_size   = 1
  asg_max_size       = 2

  rds_instance_class        = "db.t4g.micro"
  rds_allocated_storage     = 20
  rds_max_allocated_storage = 40
  rds_multi_az              = false
  rds_deletion_protection   = false
  rds_backup_retention      = 1
  rds_skip_final_snapshot   = true
  secrets_recovery_days     = 0

  alb_deletion_protection = false
}
