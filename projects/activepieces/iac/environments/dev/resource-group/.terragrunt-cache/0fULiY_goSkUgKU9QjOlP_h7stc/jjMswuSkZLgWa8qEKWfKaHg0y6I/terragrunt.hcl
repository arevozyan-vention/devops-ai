include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path = "${get_terragrunt_dir()}/../../_envcommon/resource-group.hcl"
}

include "env" {
  path = find_in_parent_folders("env.hcl")
}

inputs = {
  name     = include.root.locals.resource_group_name
  location = include.root.locals.region
  tags     = include.root.locals.common_tags
}
