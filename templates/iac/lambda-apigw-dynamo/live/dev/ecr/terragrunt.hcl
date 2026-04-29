include "root" {
  path = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/ecr.hcl"
  merge_strategy = "deep"
}

inputs = {
  repository_name = include.root.locals.name_prefix

  tags = include.root.locals.common_tags
}
