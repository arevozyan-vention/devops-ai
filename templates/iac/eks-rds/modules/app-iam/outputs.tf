output "role_arn" {
  description = "ARN of the IAM role bound to the application's Kubernetes service account."
  value       = aws_iam_role.app.arn
}

output "role_name" {
  description = "Name of the IAM role."
  value       = aws_iam_role.app.name
}
