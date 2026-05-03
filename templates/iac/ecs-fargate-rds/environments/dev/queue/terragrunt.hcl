locals {
  inputs_yaml = yamldecode(file(find_in_parent_folders("inputs.yaml")))
}

# Opt-in: deploys only when include_queue = "true" in inputs.yaml.
# Otherwise terragrunt excludes this unit from `run --all` and from any
# direct invocation. (`exclude {}` is Terragrunt 1.x; older `skip = ...`
# was removed.)
exclude {
  if                   = !try(local.inputs_yaml.include_queue == "true", false)
  actions              = ["all"]
  exclude_dependencies = false
}

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/queue.hcl"
  merge_strategy = "deep"
}

inputs = {
  name = "${include.root.locals.name_prefix}-jobs"

  # Dev sizing — short visibility timeout, modest retention, low retry budget.
  # Override per-env (env.hcl) for prod: longer visibility, higher max_receive_count.
  visibility_timeout_seconds    = 30
  message_retention_seconds     = 345600  # 4 days
  dlq_message_retention_seconds = 1209600 # 14 days
  max_receive_count             = 5

  tags = include.root.locals.common_tags
}
