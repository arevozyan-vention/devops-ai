# _envcommon/keycloak.hcl — Keycloak as a sibling ECS Fargate service.
#
# Shares cluster, ALB, RDS, secrets, and IAM roles with the main ecs-service.
# Path-routed at /auth/* on the existing ALB listener.

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/keycloak"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id          = "vpc-xxxxxxxx"
    private_subnets = ["subnet-aaaa", "subnet-bbbb"]
  }
}

dependency "ecs_cluster" {
  config_path = "../ecs-cluster"
  mock_outputs = {
    cluster_arn = "arn:aws:ecs:us-east-1:000000000000:cluster/mock"
  }
}

dependency "alb" {
  config_path = "../alb"
  mock_outputs = {
    security_group_id = "sg-xxxxxxxx"
    listeners = {
      http_only = {
        arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/mock/abc/def"
      }
    }
  }
}

dependency "rds" {
  config_path = "../rds"
  mock_outputs = {
    db_instance_address = "mock-pg.xxxxxxxx.us-east-1.rds.amazonaws.com"
  }
}

dependency "secrets" {
  config_path = "../secrets"
  mock_outputs = {
    secret_arns_by_key = {
      DB_PASSWORD             = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-DB"
      KEYCLOAK_ADMIN_PASSWORD = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-KAP"
    }
  }
}

dependency "iam" {
  config_path = "../iam"
  mock_outputs = {
    task_exec_role_arn = "arn:aws:iam::000000000000:role/mock-task-exec"
    task_role_arn      = "arn:aws:iam::000000000000:role/mock-task"
  }
}

# Keycloak depends on alb-https for the HTTPS listener ARN. The forward rule
# created inside this module (against that listener) is what associates the
# keycloak target group with the load balancer — without it, ECS refuses to
# create the service. So alb-https must apply before keycloak.
dependency "alb_https" {
  config_path = "../alb-https"
  mock_outputs = {
    https_listener_arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/mock/abc/ghi"
  }
}

locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

inputs = {
  region      = local.inputs_yaml.region
  vpc_id      = dependency.vpc.outputs.vpc_id
  subnet_ids  = dependency.vpc.outputs.private_subnets
  cluster_arn = dependency.ecs_cluster.outputs.cluster_arn

  alb_listener_arn       = dependency.alb.outputs.listeners["http_only"].arn
  alb_https_listener_arn = dependency.alb_https.outputs.https_listener_arn
  alb_security_group_id  = dependency.alb.outputs.security_group_id

  # Keycloak shares appdb with backend. Keycloak's tables (USER_ENTITY,
  # REALM, CLIENT_*, ...) don't collide with TypeORM's lowercase naming.
  rds_address = dependency.rds.outputs.db_instance_address
  db_name     = local.inputs_yaml.db_name
  db_username = local.inputs_yaml.db_master_username

  # Keycloak's DB password = the same DB_PASSWORD secret the app uses.
  # Operator copies the value from the RDS-managed master secret post-apply.
  kc_db_password_secret_arn          = lookup(dependency.secrets.outputs.secret_arns_by_key, "DB_PASSWORD", "")
  keycloak_admin_password_secret_arn = lookup(dependency.secrets.outputs.secret_arns_by_key, "KEYCLOAK_ADMIN_PASSWORD", "")

  task_exec_role_arn = dependency.iam.outputs.task_exec_role_arn
  task_role_arn      = dependency.iam.outputs.task_role_arn

  log_retention_days = tonumber(local.inputs_yaml.log_retention_days)
}
