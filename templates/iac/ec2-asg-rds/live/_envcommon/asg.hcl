# _envcommon/asg.hcl — ASG + launch template via the local app-asg module.
# All compute-side glue (security group, user-data, instance refresh) is
# encapsulated in modules/app-asg so this file stays trivial.

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/app-asg"
}

dependency "vpc"          { config_path = "../vpc" }
dependency "alb"          { config_path = "../alb" }
dependency "instance_iam" { config_path = "../instance-iam" }

locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

inputs = {
  region            = local.inputs_yaml.region
  app_port          = tonumber(local.inputs_yaml.app_port)
  health_check_path = local.inputs_yaml.health_check_path
  artifact_bucket   = local.inputs_yaml.artifact_bucket

  vpc_id     = dependency.vpc.outputs.vpc_id
  subnet_ids = dependency.vpc.outputs.private_subnets

  alb_security_group_id = dependency.alb.outputs.security_group_id
  alb_target_group_arn  = dependency.alb.outputs.target_groups["app"].arn

  instance_profile_name = dependency.instance_iam.outputs.instance_profile_name
}
