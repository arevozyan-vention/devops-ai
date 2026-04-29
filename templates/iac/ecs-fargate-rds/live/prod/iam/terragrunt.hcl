include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/iam.hcl"
  merge_strategy = "deep"
}

inputs = {
  project_name = include.root.locals.project_name
  env          = include.root.locals.env
  name_prefix  = include.root.locals.name_prefix
  common_tags  = include.root.locals.common_tags
}
