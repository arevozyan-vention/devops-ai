# live/stage/env.hcl

inputs = {
  env = "stage"

  az_suffixes      = ["a", "b"]
  vpc_cidr         = "10.50.0.0/16"
  public_subnets   = ["10.50.0.0/24",  "10.50.1.0/24"]
  private_subnets  = ["10.50.10.0/24", "10.50.11.0/24"]
  single_nat_gateway = true

  eks_instance_types = ["t3.large"]
  eks_min_size       = 2
  eks_desired_size   = 2
  eks_max_size       = 4
  eks_endpoint_public_access = false

  rds_instance_class        = "db.t4g.small"
  rds_allocated_storage     = 20
  rds_max_allocated_storage = 100
  rds_multi_az              = false
  rds_deletion_protection   = false
  rds_backup_retention      = 7
  rds_skip_final_snapshot   = false
  secrets_recovery_days     = 7
}
