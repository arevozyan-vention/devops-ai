variable "name" {
  type        = string
  description = "Replication group name. Used as prefix for SG and subnet group."
}

variable "vpc_id" {
  type        = string
  description = "VPC the cache lives in."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block — used to scope SG ingress to in-VPC sources."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet ids for the cache subnet group. Must be in private subnets (no IGW route)."
}

variable "node_type" {
  type        = string
  default     = "cache.t4g.micro"
  description = "Instance class for each cache node. cache.t4g.micro ≈ $13/mo."
}

variable "engine_version" {
  type        = string
  default     = "7.1"
  description = "Redis engine version. 7.1 supports server-side scripting + cluster API."
}

variable "num_cache_clusters" {
  type        = number
  default     = 1
  description = "Number of cache nodes. 1 = single primary (dev). >=2 enables automatic failover + multi-AZ (prod)."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources."
}
