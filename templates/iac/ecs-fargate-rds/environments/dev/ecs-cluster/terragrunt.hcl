include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/ecs-cluster.hcl"
  merge_strategy = "deep"
}

inputs = {
  cluster_name = "${include.root.locals.name_prefix}-cluster"
  tags         = include.root.locals.common_tags
}
