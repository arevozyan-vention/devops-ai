resource "aws_secretsmanager_secret" "this" {
  for_each = toset(var.secret_keys)

  name                    = "${var.project_name}/${var.env}/${each.key}"
  description             = "${var.name_prefix} — ${each.key}"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.common_tags
}
