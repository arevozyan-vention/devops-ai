locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

# Opt-in: deploys only when include_redis = "true" in inputs.yaml.
# Otherwise terragrunt excludes this unit from `run --all` and from any
# direct invocation. (`exclude {}` is Terragrunt 1.x; older `skip = ...`
# was removed.)
exclude {
  if                   = !try(local.inputs_yaml.include_redis == "true", false)
  actions              = ["all"]
  exclude_dependencies = false
}

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/redis.hcl"
  merge_strategy = "deep"
}

inputs = {
  name = "${include.root.locals.name_prefix}-redis"

  # Dev sizing — cheapest option, single node, no failover.
  node_type          = "cache.t4g.micro"
  engine_version     = "7.1"
  num_cache_clusters = 1

  tags = include.root.locals.common_tags
}
