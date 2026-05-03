# modules/queue — SQS work queue + DLQ + IAM policy attached to the ECS task role.
# Standard (non-FIFO) queue suitable for background jobs / async events.
# When messages fail to be processed `max_receive_count` times they are moved
# to the DLQ for inspection / replay.

locals {
  # task_role_arn comes in as arn:aws:iam::ACCT:role/NAME — extract NAME so the
  # policy attachment can reference the role by name (required by AWS API).
  task_role_name = element(split("/", var.task_role_arn), length(split("/", var.task_role_arn)) - 1)
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds
  tags                      = var.tags
}

resource "aws_sqs_queue" "main" {
  name                       = var.name
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = var.tags
}

# IAM policy granting the ECS task role producer + consumer access to both
# queues. Reading the DLQ is included so the app can run a replay/inspection
# tool without an extra policy.
resource "aws_iam_policy" "this" {
  name        = "${var.name}-access"
  description = "Send/receive on ${var.name} and inspect ${var.name}-dlq"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      Resource = [
        aws_sqs_queue.main.arn,
        aws_sqs_queue.dlq.arn,
      ]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = local.task_role_name
  policy_arn = aws_iam_policy.this.arn
}
