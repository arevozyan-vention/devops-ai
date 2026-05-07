output "primary_endpoint_address" {
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
  description = "Hostname of the primary node — clients should connect here."
}

output "port" {
  value       = aws_elasticache_replication_group.this.port
  description = "Port (always 6379 for Redis)."
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "SG id of the cache — consumers can reference for tighter outbound rules."
}

output "replication_group_id" {
  value       = aws_elasticache_replication_group.this.id
  description = "ElastiCache replication group identifier."
}
