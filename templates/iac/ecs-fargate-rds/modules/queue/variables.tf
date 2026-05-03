variable "name" {
  type        = string
  description = "Base name for the queue. DLQ is named '<name>-dlq'."
}

variable "task_role_arn" {
  type        = string
  description = "ARN of the ECS task role. The module attaches an IAM policy granting send/receive on the queue + DLQ to this role."
}

variable "visibility_timeout_seconds" {
  type        = number
  default     = 30
  description = "How long a message stays invisible after a consumer picks it up. Should exceed the longest-running handler in the app."
}

variable "message_retention_seconds" {
  type        = number
  default     = 345600 # 4 days
  description = "How long unprocessed messages live on the main queue before SQS drops them."
}

variable "dlq_message_retention_seconds" {
  type        = number
  default     = 1209600 # 14 days — SQS max
  description = "How long failed messages live on the DLQ. Longer than main queue to give operators time to inspect/replay."
}

variable "max_receive_count" {
  type        = number
  default     = 5
  description = "After this many failed deliveries, SQS moves the message from main → DLQ."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources."
}
