# modules/redis — ElastiCache Redis (replication group, cluster-mode disabled).
# For dev: a single primary node, no failover, encryption at rest, no auth.
# For prod the operator can flip num_cache_clusters > 1 + automatic_failover.

resource "aws_elasticache_subnet_group" "this" {
  name        = "${var.name}-cache"
  subnet_ids  = var.subnet_ids
  description = "Subnets for ${var.name} ElastiCache Redis"
  tags        = var.tags
}

resource "aws_security_group" "this" {
  name        = "${var.name}-redis-sg"
  description = "Allow inbound 6379 from inside the VPC for Redis"
  vpc_id      = var.vpc_id

  # Open to the VPC CIDR — only ECS tasks (and other in-VPC compute) can
  # reach the cache. For tighter scoping in prod, replace with explicit
  # ingress rules referencing each consumer's security_group_id.
  ingress {
    description = "Redis from inside VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "Redis for ${var.name}"

  engine               = "redis"
  engine_version       = var.engine_version
  parameter_group_name = "default.redis7"

  node_type          = var.node_type
  num_cache_clusters = var.num_cache_clusters

  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  # Single-AZ + no automatic failover for dev cost. Flip both for prod.
  automatic_failover_enabled = var.num_cache_clusters > 1
  multi_az_enabled           = var.num_cache_clusters > 1

  at_rest_encryption_enabled = true
  transit_encryption_enabled = false # dev — no TLS (simpler clients).

  apply_immediately = true

  tags = var.tags
}
