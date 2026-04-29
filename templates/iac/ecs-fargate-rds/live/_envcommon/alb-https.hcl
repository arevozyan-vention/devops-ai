# _envcommon/alb-https.hcl — provisions a self-signed cert + HTTPS listener
# alongside the existing HTTP listener on the ALB.
#
# Service-agnostic: this unit knows about the ALB but does NOT know which
# services live behind HTTPS. Every consuming module (e.g. keycloak) attaches
# its own `aws_lb_listener_rule` against `outputs.https_listener_arn`.

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/alb-https"
}

dependency "alb" {
  config_path = "../alb"
  mock_outputs = {
    arn      = "arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/mock/abc"
    dns_name = "mock-alb.us-east-1.elb.amazonaws.com"
  }
}

inputs = {
  alb_arn      = dependency.alb.outputs.arn
  alb_dns_name = dependency.alb.outputs.dns_name
}
