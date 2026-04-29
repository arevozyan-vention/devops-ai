variable "name_prefix" { type = string }
variable "common_tags" {
  type    = map(string)
  default = {}
}
variable "secret_arns" {
  type    = list(string)
  default = []
}
variable "artifact_bucket" {
  type        = string
  description = "S3 bucket the instance reads release artifacts from."
}
