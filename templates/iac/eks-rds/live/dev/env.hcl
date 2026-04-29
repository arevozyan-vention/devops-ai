# live/dev/env.hcl

inputs = {
  env = "dev"

  az_suffixes      = ["a", "b"]
  vpc_cidr         = "10.40.0.0/16"
  public_subnets   = ["10.40.0.0/24",  "10.40.1.0/24"]
  private_subnets  = ["10.40.10.0/24", "10.40.11.0/24"]
  single_nat_gateway = true

  # EKS node group
  eks_instance_types = ["t3.medium"]
  eks_min_size       = 1
  eks_desired_size   = 1
  eks_max_size       = 2
  eks_endpoint_public_access = true

  # RDS
  rds_instance_class        = "db.t4g.micro"
  rds_allocated_storage     = 20
  rds_max_allocated_storage = 40
  rds_multi_az              = false
  rds_deletion_protection   = false
  rds_backup_retention      = 1
  rds_skip_final_snapshot   = true
  secrets_recovery_days     = 0
}
