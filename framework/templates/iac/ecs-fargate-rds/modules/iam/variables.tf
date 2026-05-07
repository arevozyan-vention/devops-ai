variable "project_name" {
  description = "Short project identifier; used in role names."
  type        = string
}

variable "env" {
  description = "Environment name (dev | stage | prod)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix used in tags / display names."
  type        = string
}

variable "common_tags" {
  description = "Tags applied to every role."
  type        = map(string)
  default     = {}
}

variable "secret_arns" {
  description = "Secrets Manager ARNs the task containers must read from."
  type        = list(string)
  default     = []
}
