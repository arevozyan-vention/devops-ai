# _envcommon/ecs-service.hcl — the ECS Fargate service that actually runs
# the app. Wires together vpc, ecs-cluster, alb, ecr, rds, secrets, iam.

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
      app = { arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/mock/abc" }
    }
  }
}
dependency "ecr" {
  config_path = "../ecr"
  mock_outputs = {
    repository_url = "000000000000.dkr.ecr.us-east-1.amazonaws.com/mock"
  }
}
dependency "rds" {
  config_path = "../rds"
  mock_outputs = {
    db_instance_endpoint = "mock.cluster-xxx.us-east-1.rds.amazonaws.com:5432"
    db_instance_address  = "mock.cluster-xxx.us-east-1.rds.amazonaws.com"
  }
}
dependency "secrets" {
  config_path = "../secrets"
  mock_outputs = {
    secret_arns_by_key = {
      DB_PASSWORD             = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-DB"
      KEYCLOAK_CLIENT_SECRET  = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-KCS"
      KEYCLOAK_ADMIN_PASSWORD = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-KAP"
      JWT_SECRET              = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock-JWT"
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

locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))

  container_name = local.inputs_yaml.container_name
  container_port = tonumber(local.inputs_yaml.container_port)
  log_retention  = tonumber(local.inputs_yaml.log_retention_days)
  health_path    = local.inputs_yaml.health_check_path
}

inputs = {
  name        = "" # filled in per-env
  cluster_arn = dependency.ecs_cluster.outputs.cluster_arn

  cpu           = 256 # overridden per-env via env.hcl
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
      target_group_arn = dependency.alb.outputs.target_groups["app"].arn
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }

  container_definitions = {
    "${local.container_name}" = {
      essential = true
      image     = "${dependency.ecr.outputs.repository_url}:latest"

      port_mappings = [{
        name          = local.container_name
        containerPort = local.container_port
        protocol      = "tcp"
      }]

      readonly_root_filesystem = false

      # Non-sensitive env vars. Values that depend on other modules' outputs
      # are wired through dependency.* references — when those modules apply,
      # this task definition picks up their endpoints automatically.
      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "API_HOST", value = "0.0.0.0" },
        { name = "API_PORT", value = tostring(local.container_port) },
        { name = "API_PREFIX", value = "api/v1" },

        # DB connection — RDS endpoint resolved from the rds unit's outputs.
        { name = "DB_HOST", value = dependency.rds.outputs.db_instance_address },
        { name = "DB_PORT", value = "5432" },
        { name = "DB_NAME", value = local.inputs_yaml.db_name },
        { name = "DB_USER", value = local.inputs_yaml.db_master_username },
        { name = "DB_SYNCHRONIZE", value = "false" },
        { name = "DB_LOGGING", value = "false" },

        # Keycloak URL — same ALB, /auth path. Keycloak is provisioned as a
        # sibling ECS service when include_keycloak=true in inputs.yaml.
        # If include_keycloak=false the URL still points at /auth on the ALB
        # but nothing answers there — apps that use this var should handle it.
        # TODO(devops-ai): set KEYCLOAK_REALM and KEYCLOAK_CLIENT_ID for the
        # specific app after analyze (typical: realm = project name, client_id
        # depends on the app — e.g. "nestjs-api", "spring-api").
        { name = "KEYCLOAK_URL", value = "http://${dependency.alb.outputs.dns_name}/auth" },
        { name = "KEYCLOAK_REALM", value = local.inputs_yaml.project_name },
        { name = "KEYCLOAK_CLIENT_ID", value = "api" },
        { name = "KEYCLOAK_ADMIN", value = "admin" },

        # Out-of-skeleton — operator either deploys these or feature-flags
        # the dependent code paths in the application.
        { name = "REDIS_URL", value = "" },   # ElastiCache — not provisioned in this skeleton
        { name = "CORS_ORIGIN", value = "" }, # frontend public URL — set after frontend ships

        { name = "JWT_EXPIRATION", value = "3600" },
        { name = "CORS_CREDENTIALS", value = "true" },
      ]

      # Secret bindings — pull from Secrets Manager via valueFrom. Each name
      # MUST match a key in secrets.hcl `secret_keys` (which provisions the
      # underlying Secrets Manager entries). Operator populates the actual
      # values via `aws secretsmanager put-secret-value` after deploy-infra.
      secrets = [
        { name = "DB_PASSWORD",
        valueFrom = lookup(dependency.secrets.outputs.secret_arns_by_key, "DB_PASSWORD", "") },
        { name = "KEYCLOAK_CLIENT_SECRET",
        valueFrom = lookup(dependency.secrets.outputs.secret_arns_by_key, "KEYCLOAK_CLIENT_SECRET", "") },
        { name = "KEYCLOAK_ADMIN_PASSWORD",
        valueFrom = lookup(dependency.secrets.outputs.secret_arns_by_key, "KEYCLOAK_ADMIN_PASSWORD", "") },
        { name = "JWT_SECRET",
        valueFrom = lookup(dependency.secrets.outputs.secret_arns_by_key, "JWT_SECRET", "") },
      ]

      enable_cloudwatch_logging              = true
      cloudwatch_log_group_retention_in_days = local.log_retention

      # Container-level health check is optional. The ALB target-group health
      # check on `health_check_path` is the primary signal.
      # health_check = { command = ["CMD-SHELL", "curl -f http://localhost:${local.container_port}${local.health_path} || exit 1"] }
    }
  }
}
