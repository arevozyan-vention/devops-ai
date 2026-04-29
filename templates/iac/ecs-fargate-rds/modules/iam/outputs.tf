output "task_exec_role_arn" {
  description = "Role ECS uses to start tasks (pull image, fetch secrets, write logs)."
  value       = aws_iam_role.task_exec.arn
}

output "task_role_arn" {
  description = "Role assumed by the running task containers."
  value       = aws_iam_role.task.arn
}
