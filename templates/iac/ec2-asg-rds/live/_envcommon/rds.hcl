# _envcommon/rds.hcl — defaults for the RDS Postgres component.
# Per-env env.hcl overrides instance_class, storage size, multi_az, backup
# retention, deletion_protection.

terraform {
  source = "tfr:///terraform-aws-modules/rds/aws?version=6.10.0"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id          = "vpc-xxxxxxxx"
    private_subnets = ["subnet-aaaa", "subnet-bbbb"]
    vpc_cidr_block  = "10.0.0.0/16"
  }
}

dependency "secrets" {
  config_path = "../secrets"
  mock_outputs = {
    secret_arns_by_key = { DATABASE_PASSWORD = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock" }
  }
}

dependency "rds_sg" {
  config_path = "../rds-sg"
  mock_outputs = {
    security_group_id = "sg-xxxxxxxx"
  }
}

inputs = {
  identifier = ""  # filled in per-env via env.hcl

  engine               = "postgres"
  family               = "postgres16"
  major_engine_version = "16"
  port                 = 5432

  manage_master_user_password = true
  master_user_secret_kms_key_id = null

  storage_type      = "gp3"
  storage_encrypted = true

  iam_database_authentication_enabled = false

  vpc_security_group_ids = []  # populated via env.hcl with the rds SG
  subnet_ids             = dependency.vpc.outputs.private_subnets

  create_db_subnet_group = true

  performance_insights_enabled    = false
  monitoring_interval             = 0
  enabled_cloudwatch_logs_exports = ["postgresql"]

  copy_tags_to_snapshot = true
  skip_final_snapshot   = true   # overridden to false in prod
  apply_immediately     = false
}
