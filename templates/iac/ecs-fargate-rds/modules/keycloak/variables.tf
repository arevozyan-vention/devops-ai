variable "name" {
  description = "Resource name prefix (e.g. hiriskpro-dev-kc)"
  type        = string
}

variable "region" {
  description = "AWS region (used in awslogs config)"
  type        = string
}

# ---- networking ------------------------------------------------------------

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets to place Keycloak tasks in"
  type        = list(string)
}

# ---- ECS cluster + ALB hookup ----------------------------------------------

variable "cluster_arn" {
  type = string
}

variable "alb_listener_arn" {
  description = "Existing ALB HTTP listener (port 80). The /auth/* rule on this listener 301-redirects to HTTPS."
  type        = string
}

variable "alb_https_listener_arn" {
  description = "Existing ALB HTTPS listener (port 443), produced by the alb-https extension. The /auth/* rule on this listener forwards to the keycloak target group — this is what associates the TG with the LB so ECS can register tasks."
  type        = string
}

variable "alb_security_group_id" {
  description = "ALB SG — Keycloak SG accepts ingress from this on 8080"
  type        = string
}

# ---- RDS connection --------------------------------------------------------

variable "rds_address" {
  description = "RDS hostname (no port)"
  type        = string
}

variable "db_name" {
  description = "Logical database (Keycloak shares this with the app)"
  type        = string
}

variable "db_username" {
  description = "DB user that Keycloak connects as"
  type        = string
}

# ---- secrets ---------------------------------------------------------------

variable "kc_db_password_secret_arn" {
  description = "Secrets Manager ARN holding the DB password"
  type        = string
}

variable "keycloak_admin_password_secret_arn" {
  description = "Secrets Manager ARN holding the Keycloak admin user's password"
  type        = string
}

# ---- IAM (reused from the iam unit) ----------------------------------------

variable "task_exec_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

# ---- container -------------------------------------------------------------

variable "image" {
  description = "Keycloak container image; pulled from Docker Hub"
  type        = string
  default     = "keycloak/keycloak:25.0"
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  description = "Memory MiB. Keycloak needs ≥1024."
  type        = number
  default     = 1024
}

variable "desired_count" {
  type    = number
  default = 1
}

# ---- misc ------------------------------------------------------------------

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
