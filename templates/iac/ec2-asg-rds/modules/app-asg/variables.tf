variable "project_name" { type = string }
variable "env"          { type = string }
variable "name_prefix"  { type = string }
variable "region"       { type = string }
variable "common_tags" {
  type    = map(string)
  default = {}
}

variable "vpc_id"     { type = string }
variable "subnet_ids" { type = list(string) }

variable "alb_security_group_id" { type = string }
variable "alb_target_group_arn"  { type = string }

variable "app_port"          { type = number }
variable "health_check_path" { type = string }
variable "artifact_bucket"   { type = string }

variable "instance_profile_name" { type = string }

variable "instance_type" { type = string }
variable "min_size"      { type = number }
variable "desired_size"  { type = number }
variable "max_size"      { type = number }
