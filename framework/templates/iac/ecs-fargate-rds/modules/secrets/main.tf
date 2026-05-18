resource "aws_secretsmanager_secret" "this" {
  for_each = toset(var.secret_keys)

  name                    = "${var.project_name}/${var.env}/${each.key}"
  description             = "${var.name_prefix} — ${each.key}"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.common_tags
}

# Per-secret 64-char hex value, generated at apply time. Equivalent to
# `openssl rand -hex 32`, the convention most apps document for JWT /
# encryption / session secrets. Pre-filling here saves deploy-app's
# self-heal loop from discovering empty secrets, generating values, and
# forcing a new ECS task definition revision — that pattern costs 1-3
# minutes and 100k+ AI tokens per deploy.
#
# App-internal secrets only. External credentials (Stripe, SMTP, OAuth
# client_secret) the operator overwrites manually post-apply; the
# `ignore_changes = [secret_string]` lifecycle below prevents terraform
# from reverting those overrides on next apply.
resource "random_id" "secret_value" {
  for_each    = toset(var.secret_keys)
  byte_length = lookup(var.secret_byte_lengths, each.key, 32)
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each      = toset(var.secret_keys)
  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = random_id.secret_value[each.key].hex

  # NB: no `ignore_changes = [secret_string]`. Terraform is the source of
  # truth for system-managed secrets — RDS reads our password via Terragrunt
  # dependency, so any drift between terraform state and the actual stored
  # value would re-introduce the auth mismatch we fixed with Variant A.
  # External operator-managed secrets (Stripe, SMTP, OAuth client_secret)
  # MUST live outside this module — create them as separate
  # aws_secretsmanager_secret resources or set values via az/aws CLI on
  # secrets that are NOT in the `secret_keys` list.
}
