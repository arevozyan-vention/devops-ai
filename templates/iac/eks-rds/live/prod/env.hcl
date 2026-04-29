# live/prod/env.hcl

inputs = {
  env = "prod"

  az_suffixes      = ["a", "b"]
  vpc_cidr         = "10.60.0.0/16"
  public_subnets   = ["10.60.0.0/24",  "10.60.1.0/24"]
  private_subnets  = ["10.60.10.0/24", "10.60.11.0/24"]
  single_nat_gateway = false

  eks_instance_types = ["m6i.large"]
  eks_min_size       = 3
  eks_desired_size   = 3
  eks_max_size       = 8
  eks_endpoint_public_access = false

  rds_instance_class        = "db.t4g.medium"
  rds_allocated_storage     = 50
  rds_max_allocated_storage = 500
  rds_multi_az              = true
  rds_deletion_protection   = true
  rds_backup_retention      = 14
  rds_skip_final_snapshot   = false
  secrets_recovery_days     = 14
}
