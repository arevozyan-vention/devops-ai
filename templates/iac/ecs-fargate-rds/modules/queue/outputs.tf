output "queue_url" {
  value       = aws_sqs_queue.main.url
  description = "URL of the main work queue — clients use this for SendMessage / ReceiveMessage."
}

output "queue_arn" {
  value       = aws_sqs_queue.main.arn
  description = "ARN of the main queue. Useful for cross-account policies or CloudWatch alarms."
}

output "queue_name" {
  value       = aws_sqs_queue.main.name
  description = "Name of the main queue."
}

output "dlq_url" {
  value       = aws_sqs_queue.dlq.url
  description = "URL of the dead-letter queue — clients can poll this for failed-message replay/inspection."
}

output "dlq_arn" {
  value       = aws_sqs_queue.dlq.arn
  description = "ARN of the DLQ."
}

output "policy_arn" {
  value       = aws_iam_policy.this.arn
  description = "ARN of the IAM policy attached to the task role. Surfaced for visibility — attachment is internal."
}
