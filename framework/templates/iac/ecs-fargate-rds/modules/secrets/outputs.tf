output "secret_arns_by_key" {
  description = "Map from secret key to its Secrets Manager ARN."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}

output "all_secret_arns" {
  description = "Flat list of all provisioned secret ARNs (for IAM policies)."
  value       = [for s in aws_secretsmanager_secret.this : s.arn]
}

# Plaintext values, exposed so consumers (e.g. RDS module) can wire
# the same value as `password` and avoid the drift trap where RDS uses
# AWS-managed master_password while the app's secret holds a random
# unrelated value. Sensitive — Terragrunt won't print it in plan output.
output "secret_values_by_key" {
  description = "Map from secret key to its current generated value."
  value       = { for k in toset(var.secret_keys) : k => random_id.secret_value[k].hex }
  sensitive   = true
}
