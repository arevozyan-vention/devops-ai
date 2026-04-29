# _envcommon/rds-sg.hcl — security group for the RDS instance.

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/rds-sg"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id         = "vpc-xxxxxxxx"
    vpc_cidr_block = "10.0.0.0/16"
  }
}

inputs = {
  vpc_id              = dependency.vpc.outputs.vpc_id
  ingress_cidr_blocks = [dependency.vpc.outputs.vpc_cidr_block]
  port                = 5432
}
