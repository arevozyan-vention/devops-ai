include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rds.hcl"
  merge_strategy = "deep"
}

locals {
  env_inputs  = read_terragrunt_config(find_in_parent_folders("env.hcl")).inputs
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

inputs = {
  identifier = "${include.root.locals.name_prefix}-pg"

  engine_version = local.inputs_yaml.db_engine_version
  instance_class = local.env_inputs.rds_instance_class

  allocated_storage     = local.env_inputs.rds_allocated_storage
  max_allocated_storage = local.env_inputs.rds_max_allocated_storage

  db_name  = local.inputs_yaml.db_name
  username = local.inputs_yaml.db_master_username

  multi_az                         = local.env_inputs.rds_multi_az
  deletion_protection              = local.env_inputs.rds_deletion_protection
  backup_retention_period          = local.env_inputs.rds_backup_retention
  skip_final_snapshot              = local.env_inputs.rds_skip_final_snapshot
  final_snapshot_identifier_prefix = "${include.root.locals.name_prefix}-pg-final"

  vpc_security_group_ids = [dependency.rds_sg.outputs.security_group_id]
  subnet_ids             = dependency.vpc.outputs.private_subnets

  tags = include.root.locals.common_tags
}
