# _envcommon/alb.hcl — public Application Load Balancer.

terraform {
  source = "tfr:///terraform-aws-modules/alb/aws?version=9.17.0"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id         = "vpc-xxxxxxxx"
    public_subnets = ["subnet-aaaa", "subnet-bbbb"]
    vpc_cidr_block = "10.0.0.0/16"
  }
}

locals {
  inputs_yaml  = yamldecode(file(find_in_parent_folders("inputs.yaml")))
  domain_name  = local.inputs_yaml.domain_name
  has_domain   = local.domain_name != ""
  has_frontend = try(local.inputs_yaml.include_frontend == "true", false)

  # Default target — frontend takes the root when present, backend otherwise.
  # The listener rule below routes /api/* to backend either way.
  default_tg = local.has_frontend ? "frontend" : "app"

  # When frontend is enabled, /api/* gets forwarded to the backend ("app")
  # target group. Without frontend, no rules are needed — default forwards
  # everything to app.
  api_rules = local.has_frontend ? {
    api = {
      priority = 100
      actions = [{
        type             = "forward"
        target_group_key = "app"
      }]
      conditions = [{
        path_pattern = { values = ["/api/*"] }
      }]
    }
  } : {}
}

inputs = {
  # NOTE: do NOT set `name = ""` here — empty string survives deep-merge in
  # some terragrunt versions and conflicts with the module's `name_prefix`
  # attribute. Leaf (environments/<env>/alb/terragrunt.hcl) is responsible for
  # setting `name`.

  vpc_id  = dependency.vpc.outputs.vpc_id
  subnets = dependency.vpc.outputs.public_subnets

  enable_deletion_protection = false # flipped on in prod via env.hcl

  security_group_ingress_rules = {
    http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
    https = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  # All listener variants are declared here, each one set to `null` when its
  # condition is not met. The `for ... if v != null` filter keeps the final
  # map shape consistent and works around HCL's ternary type-equality rule.
  listeners = { for k, v in {
    redirect_http = local.has_domain ? {
      port     = 80
      protocol = "HTTP"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    } : null
    https = local.has_domain ? {
      port            = 443
      protocol        = "HTTPS"
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      certificate_arn = "" # domain_name is empty in inputs.yaml (dev) — leave blank; operator must issue ACM cert and paste ARN before deploy-infra
      forward = {
        target_group_key = local.default_tg
      }
      rules = local.api_rules
    } : null
    http_only = local.has_domain ? null : {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = local.default_tg
      }
      rules = local.api_rules
    }
  } : k => v if v != null }

  target_groups = merge(
    {
      app = {
        name_prefix       = "app-"
        protocol          = "HTTP"
        port              = 80 # placeholder; the ECS service updates the real port
        target_type       = "ip"
        create_attachment = false
        health_check = {
          enabled             = true
          path                = local.inputs_yaml.health_check_path
          matcher             = "200-399"
          interval            = 30
          timeout             = 5
          healthy_threshold   = 2
          unhealthy_threshold = 3
        }
      }
    },
    local.has_frontend ? {
      frontend = {
        name_prefix       = "fe-"
        protocol          = "HTTP"
        port              = 80
        target_type       = "ip"
        create_attachment = false
        health_check = {
          enabled             = true
          path                = local.inputs_yaml.frontend_health_check_path
          matcher             = "200-399"
          interval            = 30
          timeout             = 5
          healthy_threshold   = 2
          unhealthy_threshold = 3
        }
      }
    } : {}
  )
}
