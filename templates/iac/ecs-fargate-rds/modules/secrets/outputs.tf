output "secret_arns_by_key" {
  description = "Map from secret key to its Secrets Manager ARN."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}

output "all_secret_arns" {
  description = "Flat list of all provisioned secret ARNs (for IAM policies)."
  value       = [for s in aws_secretsmanager_secret.this : s.arn]
}
