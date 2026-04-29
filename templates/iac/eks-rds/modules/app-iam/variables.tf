variable "project_name" {
  type        = string
  description = "Project identifier."
}

variable "env" {
  type        = string
  description = "Environment name."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for IAM role names."
}

variable "common_tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to created resources."
}

variable "oidc_provider_arn" {
  type        = string
  description = "OIDC provider ARN of the EKS cluster (output from the eks module)."
}

variable "oidc_provider_url" {
  type        = string
  description = "OIDC issuer URL of the EKS cluster (without https:// prefix)."
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace the application service account lives in."
}

variable "service_account" {
  type        = string
  description = "Kubernetes service account name to bind."
}

variable "secret_arns" {
  type        = list(string)
  default     = []
  description = "Secrets Manager ARNs the workload may read."
}
