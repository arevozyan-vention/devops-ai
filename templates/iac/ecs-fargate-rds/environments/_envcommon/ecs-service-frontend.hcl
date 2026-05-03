# _envcommon/ecs-service-frontend.hcl — second ECS Fargate service for the
# frontend (typically nginx/Caddy serving a static SPA bundle, or a lightweight
# Node SSR server). Sits behind the same ALB as backend; ALB path-routing
# sends /api/* → backend ("app" target group), everything else → here.
#
# Intentionally lighter than ecs-service.hcl: no DB / Redis / Queue / Keycloak
# wiring — frontends typically don't talk to those directly. They consume
# /api on the same origin from the browser.

terraform {
  source = "tfr:///terraform-aws-modules/ecs/aws//modules/service?version=5.11.4"
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
    dns_name          = "mock-alb.us-east-1.elb.amazonaws.com"
    target_groups = {
      app      = { arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/mock-app/abc" }
      frontend = { arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/mock-fe/def" }
    }
  }
}
dependency "ecr_frontend" {
  config_path = "../ecr-frontend"
  mock_outputs = {
    repository_url = "000000000000.dkr.ecr.us-east-1.amazonaws.com/mock-frontend"
  }
}
dependency "iam" {
  config_path = "../iam"
  mock_outputs = {
    task_exec_role_arn = "arn:aws:iam::000000000000:role/mock-task-exec"
    task_role_arn      = "arn:aws:iam::000000000000:role/mock-task"
  }
}

locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))

  container_name = local.inputs_yaml.frontend_container_name
  container_port = tonumber(local.inputs_yaml.frontend_container_port)
  log_retention  = tonumber(local.inputs_yaml.log_retention_days)
}

inputs = {
  name        = "" # filled in per-env
  cluster_arn = dependency.ecs_cluster.outputs.cluster_arn

  cpu           = 256
  memory        = 512
  desired_count = 1

  enable_execute_command = true

  task_exec_iam_role_arn    = dependency.iam.outputs.task_exec_role_arn
  tasks_iam_role_arn        = dependency.iam.outputs.task_role_arn
  create_iam_role           = false
  create_task_exec_iam_role = false

  subnet_ids       = dependency.vpc.outputs.private_subnets
  assign_public_ip = false

  security_group_rules = {
    alb_ingress = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      source_security_group_id = dependency.alb.outputs.security_group_id
      description              = "Allow inbound from the ALB on the container port"
    }
    egress_all = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  load_balancer = {
    service = {
      target_group_arn = dependency.alb.outputs.target_groups["frontend"].arn
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }

  container_definitions = {
    "${local.container_name}" = {
      essential = true
      image     = "${dependency.ecr_frontend.outputs.repository_url}:latest"

      port_mappings = [{
        name          = local.container_name
        containerPort = local.container_port
        protocol      = "tcp"
      }]

      readonly_root_filesystem = false

      # Frontend doesn't need backend secrets — same-origin /api calls reach
      # the backend through the shared ALB. Add only what the static server
      # itself needs (e.g. a public CDN base if you split assets later).
      environment = [
        { name = "NODE_ENV", value = "production" },
      ]

      enable_cloudwatch_logging              = true
      cloudwatch_log_group_retention_in_days = local.log_retention
    }
  }
}
