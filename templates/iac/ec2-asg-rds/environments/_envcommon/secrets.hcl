# _envcommon/secrets.hcl — provisions empty Secrets Manager entries for the
# application. The framework AI step writes the *names* (resolved from the
# overview); the operator populates the *values* out of band after first apply.

terraform {
  source = "${dirname(find_in_parent_folders("inputs.yaml"))}/modules/secrets"
}

inputs = {
  # TODO(devops-ai): replace this list with the actual application secrets
  # discovered in the overview (database passwords, API keys, OAuth secrets, ...).
  # Each entry becomes a Secrets Manager secret named:
  #   <project_name>/<env>/<key>
  # Values are NOT written here — operator supplies them after `terragrunt apply`.
  secret_keys = [
    "DATABASE_PASSWORD",
  ]

  recovery_window_in_days = 0  # immediate delete on destroy in dev; bump to 7 in prod
}
