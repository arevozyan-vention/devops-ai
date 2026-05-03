# _envcommon/queue.hcl — SQS work queue + DLQ as an opt-in skeleton extension.
#
# Pulls the ECS task role ARN from the iam unit so the module can attach a
# send/receive policy to it. ecs-service later picks up QUEUE_URL via its own
# `dependency "queue"` block (see ecs-service.hcl).

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/queue"
}

dependency "iam" {
  config_path = "../iam"
  mock_outputs = {
    task_role_arn = "arn:aws:iam::000000000000:role/mock-task-role"
  }
}

inputs = {
  task_role_arn = dependency.iam.outputs.task_role_arn
}
