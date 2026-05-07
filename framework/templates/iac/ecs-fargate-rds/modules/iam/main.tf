data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---- task execution role (ECR pull, CloudWatch logs, secrets fetch) ---------

resource "aws_iam_role" "task_exec" {
  name               = "${var.name_prefix}-ecs-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.common_tags
}

resource "aws_iam_role_policy_attachment" "task_exec_managed" {
  role       = aws_iam_role.task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_exec_secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0

  statement {
    sid       = "ReadSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = var.secret_arns
  }
}

resource "aws_iam_role_policy" "task_exec_secrets" {
  count  = length(var.secret_arns) > 0 ? 1 : 0
  name   = "secrets-read"
  role   = aws_iam_role.task_exec.id
  policy = data.aws_iam_policy_document.task_exec_secrets[0].json
}

# ---- task role (what the application code uses at runtime) ------------------

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.common_tags
}

# Minimal default: allow the task to write its own logs. Anything else
# (S3 access, Bedrock, SQS, ...) is added by editing this module — keep
# permissions tight by default.
data "aws_iam_policy_document" "task_baseline" {
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_baseline" {
  name   = "baseline"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_baseline.json
}
