# _envcommon/vpc.hcl — only env-AGNOSTIC defaults live here.
#
# Important: in Terragrunt 1.x, merge_strategy="deep" CONCATENATES list inputs
# (does not replace). To avoid duplicating subnets, do NOT define list-typed
# defaults here that env.hcl will also set (cidr, public_subnets,
# private_subnets, azs). Each leaf must source those exclusively from env.hcl.

terraform {
  source = "tfr:///terraform-aws-modules/vpc/aws?version=5.13.0"
}

inputs = {
  enable_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []
}
