include "root" {
  path = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/rds-sg.hcl"
  merge_strategy = "deep"
}

inputs = {
  name        = "${include.root.locals.name_prefix}-rds"
  common_tags = include.root.locals.common_tags
}
