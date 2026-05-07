include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path = "${get_terragrunt_dir()}/../../_envcommon/postgres-fw.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  server_id            = dependency.postgres.outputs.server_id
  operator_ip          = ""    # set to operator's egress IP if you need psql admin access
  allow_azure_services = false # leave off; container app reaches postgres privately via VNet
}
